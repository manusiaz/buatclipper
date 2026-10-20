SET local check_function_bodies = off;

DROP TRIGGER "org_members_revoke_owner_invites" ON "market"."org_members";

DROP FUNCTION "market"."revoke_owner_invites"();

CREATE OR REPLACE FUNCTION api.set_refund_dest (
  p_refund uuid,
  p_dest   jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  r finance.org_refunds;
  o market.organizations;
  acct text := regexp_replace(coalesce(p_dest ->> 'account_no', ''), '[\s.-]', '', 'g');
  norm_name text := lower(regexp_replace(coalesce(p_dest ->> 'account_name', ''), '[^[:alnum:]]', '', 'g'));
begin
  select * into r from finance.org_refunds x where x.id = p_refund for update;
  if not found or not ops.is_org_member(r.org_id, 'brand_owner', 'brand_finance') then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    raise exception 'auth:mfa_required' using errcode = '42501';
  end if;
  if r.status <> 'requested' then
    raise exception 'invalid_state:%', r.status using errcode = 'P0001';
  end if;
  select * into o from market.organizations x where x.id = r.org_id;
  if o.org_type = 'badan' then
    -- nama legal yang baru diubah belum terverifikasi tidak boleh jadi dasar rekening tujuan (R25-2)
    if o.status <> 'verified' then
      raise exception 'org_unverified' using errcode = 'P0001', detail = 'rekening refund menunggu nama legal org terverifikasi';
    end if;
    if length(btrim(coalesce(p_dest ->> 'bank', ''))) not between 2 and 40 then
      raise exception 'invalid:bank' using errcode = 'P0001';
    end if;
    if acct !~ '^[0-9]{5,20}$' then
      raise exception 'invalid:account_no' using errcode = 'P0001';
    end if;
    if norm_name = '' or norm_name <> lower(regexp_replace(coalesce(o.legal_name, ''), '[^[:alnum:]]', '', 'g')) then
      raise exception 'refund_name_mismatch' using errcode = 'P0001', detail = 'nama rekening harus sama dengan nama legal org';
    end if;
    update finance.org_refunds set dest_bank = btrim(p_dest ->> 'bank'), dest_account = acct, dest_name = btrim(p_dest ->> 'account_name'),
           dest_set_by = uid
     where id = r.id;
  else
    if not market.is_direct_member(r.org_id, uid, 'brand_owner') then
      raise exception 'auth:forbidden' using errcode = '42501', detail = 'org perorangan: rekening refund milik pemilik org';
    end if;
    if p_dest ->> 'owner_account' is distinct from 'true' then
      raise exception 'invalid:owner_account' using errcode = 'P0001';
    end if;
    update finance.org_refunds set dest_bank = null, dest_account = null, dest_name = null, dest_set_by = uid where id = r.id;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'refund.dest', 'refund:' || r.id,
          jsonb_build_object('bank', r.dest_bank, 'account_last4', right(r.dest_account, 4), 'set_by', r.dest_set_by),
          jsonb_build_object('bank', p_dest ->> 'bank', 'account_last4', nullif(right(acct, 4), ''), 'owner_account', o.org_type = 'perorangan'));
end $function$;

CREATE OR REPLACE FUNCTION market.on_owner_lost()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner') then
    delete from market.org_invites where org_id = old.org_id and created_by = old.user_id and accepted_at is null;
    with r as (
      update finance.org_refunds x
         set dest_set_by = null, status = 'requested', approved_by = null
       where x.org_id = old.org_id and x.dest_set_by = old.user_id and x.dest_account is null
         and x.status in ('requested', 'approved')
      returning x.id)
    insert into ops.audit_logs (actor_id, action, target, after)
    select (select auth.uid()), 'refund.dest_reset', 'refund:' || r.id, jsonb_build_object('reason', 'owner_lost', 'user_id', old.user_id)
      from r;
  end if;
  return null;
end $function$;

CREATE TRIGGER org_members_owner_lost
  AFTER DELETE OR UPDATE ON market.org_members
  FOR EACH ROW
  EXECUTE FUNCTION market.on_owner_lost();

REVOKE ALL ON FUNCTION "market"."on_owner_lost"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."on_owner_lost"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."on_owner_lost"() TO "postgres";
