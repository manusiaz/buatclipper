SET local check_function_bodies = off;

DROP VIEW "api"."org_refunds";

ALTER TABLE "finance"."org_refunds"
  ADD COLUMN "dest_bank" text;

ALTER TABLE "finance"."org_refunds"
  ADD COLUMN "dest_account" text;

ALTER TABLE "finance"."org_refunds"
  ADD COLUMN "dest_name" text;

ALTER TABLE "finance"."org_refunds"
  ADD COLUMN "dest_method_id" uuid;

ALTER TABLE "finance"."org_refunds"
  ADD COLUMN "dest_set_by" uuid;

CREATE OR REPLACE FUNCTION api.approve_refund (
  p_refund uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from finance.org_refunds r where r.id = p_refund and r.status = 'requested' and r.dest_set_by is null) then
    raise exception 'refund_dest_missing' using errcode = 'P0001', detail = 'brand belum mengisi rekening tujuan';
  end if;
  update finance.org_refunds set status = 'approved', approved_by = (select auth.uid()) where id = p_refund and status = 'requested';
  if not found then
    raise exception 'invalid_state:refund' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'refund.approve', 'refund:' || p_refund, '{"status": "requested"}', '{"status": "approved"}');
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_get_refund (
  p_refund uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r finance.org_refunds;
begin
  select * into r from finance.org_refunds x where x.id = p_refund;
  if not found then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', r.id, 'status', r.status, 'requested_by', r.requested_by, 'approved_by', r.approved_by,
                            'dest_method_id', r.dest_method_id, 'dest_set_by', r.dest_set_by, 'amount', r.amount,
                            'fee', r.transfer_fee);
end $function$;

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
           dest_method_id = null, dest_set_by = uid
     where id = r.id;
  else
    if not market.is_direct_member(r.org_id, uid, 'brand_owner') then
      raise exception 'auth:forbidden' using errcode = '42501', detail = 'org perorangan: rekening refund milik pemilik org';
    end if;
    if coalesce(p_dest ->> 'method_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'invalid:method_id' using errcode = 'P0001';
    end if;
    update finance.org_refunds set dest_bank = null, dest_account = null, dest_name = null,
           dest_method_id = (p_dest ->> 'method_id')::uuid, dest_set_by = uid
     where id = r.id;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'refund.dest', 'refund:' || r.id,
          jsonb_build_object('bank', r.dest_bank, 'account_last4', right(r.dest_account, 4), 'method_id', r.dest_method_id),
          jsonb_build_object('bank', p_dest ->> 'bank', 'account_last4', nullif(right(acct, 4), ''), 'method_id', p_dest ->> 'method_id'));
end $function$;

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_dest_account_check" CHECK ((dest_account ~ '^[0-9]{5,20}$'::text));

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_dest_bank_check" CHECK (((length(dest_bank) >= 2) AND (length(dest_bank) <= 40)));

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_dest_name_check" CHECK (((length(dest_name) >= 2) AND (length(dest_name) <= 200)));

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_dest"
    CHECK
    (((num_nonnulls(dest_bank, dest_account, dest_name) = ANY (ARRAY[0, 3])) AND (num_nonnulls(dest_account, dest_method_id) <= 1) AND ((dest_set_by IS NULL) =
    (num_nonnulls(dest_account, dest_method_id) = 0))));

CREATE VIEW "api"."org_refunds" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    campaign_id,
    amount,
    transfer_fee,
    status,
    requested_by,
    created_at,
    paid_at,
    bank_ref,
    dest_bank,
    dest_account,
    dest_name,
    dest_method_id
   FROM finance.org_refunds;

REVOKE ALL ON FUNCTION "api"."bridge_get_refund"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_get_refund"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_refund"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_refund"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."set_refund_dest"(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."set_refund_dest"(uuid, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."set_refund_dest"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."set_refund_dest"(uuid, jsonb) TO "postgres";

GRANT SELECT ON TABLE "api"."org_refunds" TO "authenticated";
