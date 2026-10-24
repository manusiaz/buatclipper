SET local check_function_bodies = off;

DROP TRIGGER "org_members_keep_owner" ON "market"."org_members";

DROP TRIGGER "org_members_owner_lost" ON "market"."org_members";

DROP VIEW "api"."org_invites";

ALTER TABLE "market"."org_invites"
  DROP CONSTRAINT "org_invites_accepted_by_fkey";

ALTER TABLE "market"."org_invites"
  DROP CONSTRAINT "org_invites_created_by_fkey";

ALTER TABLE "market"."org_invites"
  DROP CONSTRAINT "org_invites_org_id_fkey";

DROP FUNCTION "api"."accept_org_invite"(text);

DROP FUNCTION "api"."create_org"(text, text, text, text, text, boolean);

DROP FUNCTION "api"."create_org_invite"(uuid, text);

DROP FUNCTION "api"."invite_preview"(text);

DROP FUNCTION "api"."link_agency"(uuid, uuid, text);

DROP FUNCTION "api"."manage_team"(uuid, text, uuid, text);

DROP FUNCTION "api"."update_org"(uuid, text, text, text, text);

DROP FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text);

DROP FUNCTION "market"."keep_one_owner"();

DROP FUNCTION "market"."on_owner_lost"();

DROP TABLE "market"."org_invites";

CREATE OR REPLACE FUNCTION api.bridge_refund_revealed (
  p_refund      uuid,
  p_dest_set_by uuid
)
  RETURNS void
  LANGUAGE plpgsql
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
  -- anggota dikunci sebelum refund (urutan sama dengan owner hilang → bus_in.org_owner_lost): tanpa deadlock
  if not market.is_direct_member(r.org_id, p_dest_set_by, 'brand_owner') then
    raise exception 'refund_dest_invalid' using errcode = 'P0001', detail = 'pemilik rekening bukan owner org lagi';
  end if;
  select * into r from finance.org_refunds x where x.id = p_refund for update;
  if r.status <> 'approved' or r.dest_account is not null or r.dest_set_by is distinct from p_dest_set_by then
    raise exception 'refund_dest_invalid' using errcode = 'P0001', detail = 'tujuan atau persetujuan refund berubah';
  end if;
  update finance.org_refunds set transfer_started_at = coalesce(transfer_started_at, now()) where id = r.id;
end $function$;

CREATE OR REPLACE FUNCTION api.manage_org (
  p_org    uuid,
  p_action text,
  p_params jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  o market.organizations;
  new_rule uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_super aal2', '42501');
  end if;
  if p_action is distinct from 'set_fee' then
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
  select * into o from market.organizations where id = p_org for update;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if jsonb_typeof(prm) = 'null' or prm = '{}'::jsonb or coalesce((prm ->> 'clear')::boolean, false) then
    new_rule := null;
  else
    new_rule := finance.create_fee_rule('org', prm, finance.effective_fee_rule(null, null), uid);
  end if;
  update market.organizations set fee_rule_id = new_rule where id = o.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.set_fee', 'org:' || o.id,
          (select to_jsonb(f) from finance.fee_rules f where f.id = o.fee_rule_id),
          (select to_jsonb(f) from finance.fee_rules f where f.id = new_rule));
end $function$;

CREATE OR REPLACE FUNCTION api.record_review (
  p_target_type text,
  p_target_id   uuid,
  p_decision    text,
  p_reason      text DEFAULT NULL::text,
  p_message     text DEFAULT NULL::text,
  p_note        text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  s record;
  is_admin boolean;
begin
  if p_target_type = 'campaign' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    select * into c from market.campaigns where id = p_target_id for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if c.status <> 'in_review' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign in_review yang bisa direview');
    end if;
    if p_decision = 'approve' then
      if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'campaign' and i.status = 'paid') then
        perform market.fail('invoice_unpaid', 'invoice campaign belum lunas');
      end if;
      -- Paket managed (REV-3): jasa tim internal juga harus lunas sebelum campaign tayang.
      if exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'managed_service' and i.status = 'issued') then
        perform market.fail('invoice_unpaid', 'invoice paket managed belum lunas');
      end if;
      update market.campaigns set status = 'scheduled' where id = c.id;
    elsif p_decision = 'reject' then
      if nullif(btrim(p_reason), '') is null then
        perform market.fail('invalid:reason', 'penolakan wajib alasan');
      end if;
      update market.campaigns set status = 'rejected' where id = c.id;
    else
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('campaign', c.id, uid, p_decision, p_reason, p_message, p_note);
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[],
                              case p_decision when 'approve' then 'campaign.approved' else 'campaign.rejected' end,
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.campaign.' || p_decision, 'campaign:' || c.id, jsonb_build_object('status', c.status),
            jsonb_build_object('status', case p_decision when 'approve' then 'scheduled' else 'rejected' end, 'reason', p_reason));

  elsif p_target_type = 'submission' then
    if p_decision not in ('approve', 'reject', 'overturn', 'uphold') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    select sb.id, sb.status, sb.user_id, k.org_id, k.review_mode into s
      from tracking.submissions sb join market.campaigns k on k.id = sb.campaign_id where sb.id = p_target_id
       for update of sb; -- otorisasi brand memakai status yang sama dengan yang diubah keputusan (tidak balapan dengan reject+banding)
    if s.id is null then
      perform market.fail('not_found:submission', null, 'P0002');
    end if;
    is_admin := ops.has_admin('admin_moderator');
    if not is_admin and not (s.review_mode = 'brand' and s.status = 'in_review'
                             and s.user_id <> uid  -- tidak mereview clip sendiri (R67)
                             and ops.is_org_member(s.org_id, 'brand_owner', 'brand_manager')) then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2 atau brand_owner/brand_manager (review brand)', '42501');
    end if;
    perform trust.apply_submission_decision(s.id, p_decision, uid, p_reason, p_message, p_note);
    if is_admin then
      insert into ops.audit_logs (actor_id, action, target, before, after)
      values (uid, 'review.submission.' || p_decision, 'submission:' || s.id, jsonb_build_object('status', s.status),
              jsonb_build_object('status', (select x.status from tracking.submissions x where x.id = s.id), 'reason', p_reason));
    end if;

  elsif p_target_type = 'kyc' then
    -- Keputusan KYC diputus di identity (admin_kyc_decision); core hanya mencatat (tanpa PII) + mengabari user.
    if not ops.has_admin('admin_moderator') then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    if p_decision = 'reject' and nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if not exists (select 1 from market.profiles pr where pr.id = p_target_id) then
      perform market.fail('not_found:profile', null, 'P0002');
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('kyc', p_target_id, uid, p_decision, p_reason, p_message, p_note);
    -- Referral (F-C16) berlaku sejak KYC disetujui, bukan sejak withdraw pertama (earning di antaranya ikut dihitung).
    if p_decision = 'approve' then
      update market.referrals set qualified_at = now(),
             bonus_until = now() + make_interval(days => (ops.cfg('finance.referral_bonus_days', '90'))::int)
       where referred_id = p_target_id and qualified_at is null;
    end if;
    perform ops.enqueue_notification(p_target_id, case p_decision when 'approve' then 'kyc.approved' else 'kyc.rejected' end,
                                     jsonb_build_object('decision', p_decision, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.kyc.' || p_decision, 'profile:' || p_target_id, null, jsonb_build_object('reason', p_reason));

  else
    perform market.fail('invalid:target_type', coalesce(p_target_type, 'null'));
  end if;
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
  select * into r from finance.org_refunds x where x.id = p_refund;
  if not found or not ops.is_org_member(r.org_id, 'brand_owner', 'brand_finance') then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    raise exception 'auth:mfa_required' using errcode = '42501';
  end if;
  select * into o from market.organizations x where x.id = r.org_id;
  -- baris anggota dikunci (FOR SHARE) sebelum baris refund: urutan sama dengan owner hilang → bus_in.org_owner_lost (R26-2)
  if o.org_type <> 'badan' and not market.is_direct_member(r.org_id, uid, 'brand_owner') then
    raise exception 'auth:forbidden' using errcode = '42501', detail = 'org perorangan: rekening refund milik pemilik org';
  end if;
  select * into r from finance.org_refunds x where x.id = p_refund for update;
  if r.status <> 'requested' then
    raise exception 'invalid_state:%', r.status using errcode = 'P0001';
  end if;
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

CREATE OR REPLACE FUNCTION bus_in.audit_log (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into ops.audit_logs (actor_id, action, target, before, after, at)
  select r.actor_id, r.action, r.target, r.before, r.after, coalesce(r.at, now()) from jsonb_populate_record(null::ops.audit_logs, p) r;
$function$;

CREATE OR REPLACE FUNCTION bus_in.notify_user (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  perform ops.enqueue_notification((p ->> 'user_id')::uuid, p ->> 'event', coalesce(p -> 'payload', '{}'),
                                   coalesce((p ->> 'email')::boolean, true));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.org_owner_lost (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  v_org uuid := (p ->> 'org_id')::uuid;
  v_user uuid := (p ->> 'user_id')::uuid;
begin
  perform 1 from market.org_members m where m.org_id = v_org and m.user_id = v_user for update;
  with r as (
    update finance.org_refunds x
       set dest_set_by = null, status = 'requested', approved_by = null
     where x.org_id = v_org and x.dest_set_by = v_user and x.dest_account is null
       and (x.status = 'requested' or (x.status = 'approved' and x.transfer_started_at is null))
    returning x.id)
  insert into ops.audit_logs (actor_id, action, target, after)
  select (p ->> 'actor_id')::uuid, 'refund.dest_reset', 'refund:' || r.id, jsonb_build_object('reason', 'owner_lost', 'user_id', v_user)
    from r;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.profile_ensure (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  perform market.ensure_member_profile((p ->> 'user_id')::uuid, p ->> 'username', p ->> 'display_name');
end $function$;

CREATE OR REPLACE FUNCTION bus_in.review_decision (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  select r.target_type, r.target_id, r.actor_id, r.decision, r.reason_code, r.message, r.note
    from jsonb_populate_record(null::trust.review_decisions, p) r;
$function$;

CREATE TRIGGER profiles_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.profiles
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:username,display_name,avatar_path,status,suspended_until');

REVOKE ALL ON FUNCTION "bus_in"."audit_log"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."audit_log"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."audit_log"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."notify_user"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."notify_user"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."notify_user"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."org_owner_lost"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."org_owner_lost"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."org_owner_lost"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."profile_ensure"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."profile_ensure"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."profile_ensure"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."review_decision"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."review_decision"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."review_decision"(jsonb) TO "postgres";
