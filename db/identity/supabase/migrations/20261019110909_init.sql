SET local check_function_bodies = off;

CREATE SCHEMA "api";

CREATE SCHEMA "member";

CREATE EXTENSION IF NOT EXISTS "pg_cron";

CREATE EXTENSION IF NOT EXISTS "pg_net" SCHEMA "extensions";

CREATE TABLE "member"."audit_logs" (
  "id"       bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "actor_id" uuid,
  "action"   text                     NOT NULL,
  "target"   text                     NOT NULL,
  "before"   jsonb,
  "after"    jsonb,
  "at"       timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "audit_logs_action_check" CHECK ((action ~ '^[a-z_]+(\.[a-z_]+)+$'::text)),
  CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id)
);

ALTER TABLE "member"."audit_logs"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."consents" (
  "id"         bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "version"    text                     NOT NULL,
  "granted_at" timestamp with time zone NOT NULL DEFAULT now(),
  "revoked_at" timestamp with time zone,
  CONSTRAINT "consents_pkey" PRIMARY KEY (id),
  CONSTRAINT "consents_revoked_after_granted" CHECK (((revoked_at IS NULL) OR (revoked_at >= granted_at))),
  CONSTRAINT "consents_version_check" CHECK ((version ~ '^\d{4}-\d{2}-\d{2}$'::text))
);

ALTER TABLE "member"."consents"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."kyc_records" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid,
  "nik_hash"        bytea,
  "nik_enc"         bytea,
  "nik_last4"       text,
  "enc_key_version" smallint,
  "legal_name"      text,
  "doc_ref"         text,
  "reject_reason"   text,
  "submitted_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "decided_at"      timestamp with time zone,
  "decided_by"      uuid,
  "blocked"         boolean                  NOT NULL DEFAULT false,
  "retain_until"    date,
  CONSTRAINT "kyc_active_complete" CHECK (((user_id IS NULL) OR ((nik_hash IS NOT NULL) AND (nik_enc IS NOT NULL) AND (nik_last4 IS NOT NULL) AND (enc_key_version IS
    NOT NULL) AND (legal_name IS NOT NULL) AND (doc_ref IS NOT NULL)))),
  CONSTRAINT "kyc_doc_in_own_folder" CHECK (((user_id IS NULL) OR (doc_ref ~~ ((user_id)::text || '/%'::text)))),
  CONSTRAINT "kyc_nik_unique" UNIQUE (nik_hash),
  CONSTRAINT "kyc_records_enc_key_version_check" CHECK ((enc_key_version > 0)),
  CONSTRAINT "kyc_records_legal_name_check" CHECK (((char_length(legal_name) >= 2) AND (char_length(legal_name) <= 100))),
  CONSTRAINT "kyc_records_nik_hash_check" CHECK ((octet_length(nik_hash) = 32)),
  CONSTRAINT "kyc_records_nik_last4_check" CHECK ((nik_last4 ~ '^[0-9]{4}$'::text)),
  CONSTRAINT "kyc_records_pkey" PRIMARY KEY (id),
  CONSTRAINT "kyc_records_user_id_key" UNIQUE (user_id),
  CONSTRAINT "kyc_tombstone_reason" CHECK (((user_id IS NOT NULL) OR blocked OR (retain_until IS NOT NULL)))
);

ALTER TABLE "member"."kyc_records"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."legal_versions" (
  "version"      text                     NOT NULL,
  "published_at" timestamp with time zone NOT NULL DEFAULT now(),
  "url"          text                     NOT NULL,
  CONSTRAINT "legal_versions_url_check" CHECK ((url ~ '^https://'::text)),
  CONSTRAINT "legal_versions_version_check" CHECK ((version ~ '^\d{4}-\d{2}-\d{2}$'::text))
);

ALTER TABLE "member"."legal_versions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."payout_methods" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid,
  "kind"            text                     NOT NULL,
  "bank_code"       text                     NOT NULL,
  "account_no_hash" bytea                    NOT NULL,
  "account_no_enc"  bytea,
  "account_last4"   text,
  "account_name"    text,
  "enc_key_version" smallint,
  "verified_at"     timestamp with time zone,
  "disabled_at"     timestamp with time zone,
  "blocked"         boolean                  NOT NULL DEFAULT false,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "payout_methods_account_last4_check" CHECK ((account_last4 ~ '^[0-9]{4}$'::text)),
  CONSTRAINT "payout_methods_account_name_check" CHECK (((char_length(account_name) >= 2) AND (char_length(account_name) <= 100))),
  CONSTRAINT "payout_methods_account_no_hash_check" CHECK ((octet_length(account_no_hash) = 32)),
  CONSTRAINT "payout_methods_account_unique" UNIQUE (bank_code, account_no_hash),
  CONSTRAINT "payout_methods_active_complete" CHECK (((user_id IS NULL) OR ((account_no_enc IS NOT NULL) AND (account_last4 IS NOT NULL) AND (account_name IS
    NOT NULL) AND (enc_key_version IS NOT NULL)))),
  CONSTRAINT "payout_methods_bank_code_check" CHECK ((bank_code ~ '^[A-Z0-9_]{2,20}$'::text)),
  CONSTRAINT "payout_methods_enc_key_version_check" CHECK ((enc_key_version > 0)),
  CONSTRAINT "payout_methods_kind_check" CHECK ((kind = ANY (ARRAY['bank'::text, 'ewallet'::text]))),
  CONSTRAINT "payout_methods_pkey" PRIMARY KEY (id),
  CONSTRAINT "payout_methods_tombstone_blocked" CHECK (((user_id IS NOT NULL) OR blocked))
);

ALTER TABLE "member"."payout_methods"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."platform_roles" (
  "user_id"    uuid                     NOT NULL,
  "granted_by" uuid,
  "granted_at" timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE "member"."platform_roles"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."push_subscriptions" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"      uuid                     NOT NULL,
  "endpoint"     text                     NOT NULL,
  "p256dh"       text                     NOT NULL,
  "auth_secret"  text                     NOT NULL,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "last_used_at" timestamp with time zone,
  CONSTRAINT "push_subscriptions_endpoint_check" CHECK ((endpoint ~ '^https://'::text)),
  CONSTRAINT "push_subscriptions_endpoint_unique" UNIQUE (endpoint),
  CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY (id)
);

ALTER TABLE "member"."push_subscriptions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."recipient_details" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid                     NOT NULL,
  "reward_type_id"  uuid                     NOT NULL,
  "data_enc"        bytea                    NOT NULL,
  "enc_key_version" smallint                 NOT NULL,
  "updated_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "recipient_details_enc_key_version_check" CHECK ((enc_key_version > 0)),
  CONSTRAINT "recipient_details_pkey" PRIMARY KEY (id),
  CONSTRAINT "recipient_one_per_reward_type" UNIQUE (user_id, reward_type_id)
);

ALTER TABLE "member"."recipient_details"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "member"."consent_kind" AS ENUM (
  'tos_clipper',
  'tos_brand',
  'privacy',
  'age_18_plus',
  'kyc',
  'share_with_brand'
);

ALTER TABLE "member"."consents"
  ADD COLUMN "kind" member.consent_kind NOT NULL;

ALTER TABLE "member"."legal_versions"
  ADD COLUMN "kind" member.consent_kind NOT NULL;

CREATE TYPE "member"."kyc_status" AS ENUM (
  'pending',
  'approved',
  'rejected'
);

ALTER TABLE "member"."kyc_records"
  ADD COLUMN "status" member.kyc_status NOT NULL DEFAULT 'pending'::member.kyc_status;

CREATE TYPE "member"."platform_role" AS ENUM (
  'admin_super',
  'admin_ops',
  'admin_moderator',
  'admin_finance',
  'admin_support'
);

ALTER TABLE "member"."platform_roles"
  ADD COLUMN "role" member.platform_role NOT NULL;

CREATE OR REPLACE FUNCTION api.admin_kyc_decision (
  p_user_id  uuid,
  p_decision member.kyc_status,
  p_reason   text              DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not member.is_admin('admin_moderator') then
    raise exception 'butuh admin_moderator + aal2' using errcode = '42501';
  end if;
  if p_decision = 'pending' then
    raise exception 'keputusan harus approved atau rejected' using errcode = '22023';
  end if;
  update member.kyc_records
     set status = p_decision,
         reject_reason = case when p_decision = 'rejected' then p_reason end,
         decided_at = now(),
         decided_by = (select auth.uid())
   where user_id = p_user_id and status = 'pending';
  if not found then
    raise exception 'tidak ada KYC menunggu untuk user ini' using errcode = 'P0002';
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'kyc.decide', 'user:' || p_user_id,
          jsonb_build_object('status', p_decision, 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.admin_read (
  p_user_id uuid
)
  RETURNS TABLE (
    user_id        uuid,
    legal_name     text,
    nik_last4      text,
    doc_ref        text,
    status         member.kyc_status,
    submitted_at   timestamp with time zone,
    payout_methods jsonb
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not member.is_admin('admin_moderator', 'admin_support', 'admin_finance') then
    raise exception 'butuh role admin + aal2' using errcode = '42501';
  end if;
  insert into member.audit_logs (actor_id, action, target)
  values ((select auth.uid()), 'pii.read', 'user:' || p_user_id);
  return query
    select k.user_id, k.legal_name, k.nik_last4, k.doc_ref, k.status, k.submitted_at,
           (select coalesce(jsonb_agg(jsonb_build_object('id', pm.id, 'bank_code', pm.bank_code,
                                                         'last4', pm.account_last4, 'name', pm.account_name)), '[]'::jsonb)
              from member.payout_methods pm where pm.user_id = p_user_id)
    from member.kyc_records k where k.user_id = p_user_id;
end $function$;

CREATE OR REPLACE FUNCTION api.admin_set_role (
  p_user_id uuid,
  p_role    member.platform_role,
  p_grant   boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and p_role = 'admin_super' and not p_grant then
    raise exception 'tidak bisa mencabut admin_super milik sendiri' using errcode = '22023';
  end if;
  if p_grant then
    insert into member.platform_roles (user_id, role, granted_by)
    values (p_user_id, p_role, (select auth.uid()))
    on conflict (user_id, role) do nothing;
  else
    delete from member.platform_roles where user_id = p_user_id and role = p_role;
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), case when p_grant then 'role.grant' else 'role.revoke' end, 'user:' || p_user_id,
          jsonb_build_object('role', p_role));
end $function$;

CREATE OR REPLACE FUNCTION api.my_payout_methods()
  RETURNS TABLE (
    id            uuid,
    kind          text,
    bank_code     text,
    account_last4 text,
    account_name  text,
    verified_at   timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select pm.id, pm.kind, pm.bank_code, pm.account_last4, pm.account_name, pm.verified_at
  from member.payout_methods pm
  where pm.user_id = (select auth.uid()) and pm.disabled_at is null
  order by pm.created_at;
$function$;

CREATE OR REPLACE FUNCTION api.record_consent (
  p_kind    member.consent_kind,
  p_version text                DEFAULT NULL::text,
  p_granted boolean             DEFAULT true
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  v text;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  if not p_granted then
    update member.consents set revoked_at = now()
     where user_id = uid and kind = p_kind and revoked_at is null;
    return;
  end if;
  if p_kind in ('tos_clipper', 'tos_brand', 'privacy') then
    select max(lv.version) into v from member.legal_versions lv where lv.kind = p_kind and lv.published_at <= now();
    if v is null or p_version is distinct from v then
      raise exception 'versi % bukan versi terbaru untuk %', p_version, p_kind using errcode = '22023';
    end if;
  else
    v := coalesce(p_version, to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD'));
  end if;
  insert into member.consents (user_id, kind, version) values (uid, p_kind, v)
  on conflict (user_id, kind, version) do update set revoked_at = null, granted_at = now()
    where member.consents.revoked_at is not null;
end $function$;

CREATE OR REPLACE FUNCTION api.save_push_subscription (
  p_endpoint text,
  p_p256dh   text,
  p_auth     text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  sid uuid;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  insert into member.push_subscriptions (user_id, endpoint, p256dh, auth_secret)
  values (uid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh,
    auth_secret = excluded.auth_secret, created_at = now()
  returning id into sid;
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.shared_device_groups (
  p_since        interval DEFAULT '1 day'::interval,
  p_min_accounts integer  DEFAULT 3
)
  RETURNS TABLE (
    ip         inet,
    user_agent text,
    user_ids   uuid[]
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select s.ip, s.user_agent, array_agg(distinct s.user_id)
  from auth.sessions s
  where s.created_at > now() - p_since and s.ip is not null
  group by s.ip, s.user_agent
  having count(distinct s.user_id) >= p_min_accounts;
$function$;

CREATE OR REPLACE FUNCTION api.store_kyc (
  p_user_id     uuid,
  p_nik_hash    bytea,
  p_nik_enc     bytea,
  p_nik_last4   text,
  p_key_version smallint,
  p_legal_name  text,
  p_doc_ref     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from member.kyc_records k where k.nik_hash = p_nik_hash and k.user_id is distinct from p_user_id) then
    raise exception 'NIK sudah dipakai akun lain' using errcode = '23505';
  end if;
  insert into member.kyc_records (user_id, nik_hash, nik_enc, nik_last4, enc_key_version, legal_name, doc_ref)
  values (p_user_id, p_nik_hash, p_nik_enc, p_nik_last4, p_key_version, p_legal_name, p_doc_ref)
  on conflict (user_id) do update
    set nik_hash = excluded.nik_hash, nik_enc = excluded.nik_enc, nik_last4 = excluded.nik_last4,
        enc_key_version = excluded.enc_key_version, legal_name = excluded.legal_name, doc_ref = excluded.doc_ref,
        status = 'pending', reject_reason = null, decided_at = null, decided_by = null, submitted_at = now()
    where member.kyc_records.status = 'rejected';
  if not found then
    raise exception 'KYC sudah dikirim dan belum ditolak' using errcode = '23505';
  end if;
  insert into member.audit_logs (actor_id, action, target) values (p_user_id, 'kyc.submit', 'user:' || p_user_id);
end $function$;

CREATE OR REPLACE FUNCTION api.store_payout_method (
  p_user_id         uuid,
  p_kind            text,
  p_bank_code       text,
  p_account_no_hash bytea,
  p_account_no_enc  bytea,
  p_last4           text,
  p_key_version     smallint,
  p_account_name    text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  kyc_name text;
  new_id uuid;
begin
  select k.legal_name into kyc_name from member.kyc_records k where k.user_id = p_user_id and k.status <> 'rejected';
  if kyc_name is null then
    raise exception 'lengkapi KYC dulu' using errcode = '22023';
  end if;
  if lower(regexp_replace(btrim(kyc_name), '\s+', ' ', 'g')) <> lower(regexp_replace(btrim(p_account_name), '\s+', ' ', 'g')) then
    raise exception 'nama pemilik rekening harus sama dengan nama KYC' using errcode = '22023';
  end if;
  insert into member.payout_methods (user_id, kind, bank_code, account_no_hash, account_no_enc, account_last4,
                                     account_name, enc_key_version)
  values (p_user_id, p_kind, p_bank_code, p_account_no_hash, p_account_no_enc, p_last4, p_account_name, p_key_version)
  returning id into new_id;
  insert into member.audit_logs (actor_id, action, target) values (p_user_id, 'payout_method.add', 'payout_method:' || new_id);
  return new_id;
end $function$;

CREATE OR REPLACE FUNCTION api.store_recipient (
  p_user_id        uuid,
  p_reward_type_id uuid,
  p_data_enc       bytea,
  p_key_version    smallint
)
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  insert into member.recipient_details (user_id, reward_type_id, data_enc, enc_key_version)
  values (p_user_id, p_reward_type_id, p_data_enc, p_key_version)
  on conflict (user_id, reward_type_id) do update
    set data_enc = excluded.data_enc, enc_key_version = excluded.enc_key_version, updated_at = now()
  returning id;
$function$;

CREATE OR REPLACE FUNCTION api.svc_audit (
  p_actor  uuid,
  p_action text,
  p_target text,
  p_after  jsonb DEFAULT NULL::jsonb
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  insert into member.audit_logs (actor_id, action, target, after) values (p_actor, p_action, p_target, p_after);
$function$;

CREATE OR REPLACE FUNCTION api.svc_check_ids (
  p_user_ids       uuid[],
  p_method_ids     uuid[],
  p_recipient_refs uuid[]
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select jsonb_build_object(
    'user_ids', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_user_ids) as x (id)
                          where x.id is not null
                            and not exists (select 1 from auth.users u where u.id = x.id)), '[]'::jsonb),
    'method_ids', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_method_ids) as x (id)
                            where x.id is not null
                              and not exists (select 1 from member.payout_methods pm
                                              where pm.id = x.id and pm.user_id is not null)), '[]'::jsonb),
    'recipient_refs', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_recipient_refs) as x (id)
                                where x.id is not null
                                  and not exists (select 1 from member.recipient_details r where r.id = x.id)), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION api.svc_close_member (
  p_user         uuid,
  p_blocked      boolean,
  p_retain_until date
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  kyc_id uuid;
  kyc_result text := 'none';
  pm_deleted int := 0;
  pm_tombstoned int := 0;
begin
  if p_user is null or p_blocked is null then
    raise exception 'p_user dan p_blocked wajib' using errcode = '22023';
  end if;
  if p_retain_until is not null and p_retain_until <= current_date then
    raise exception 'retain_until harus setelah hari ini' using errcode = '22023';
  end if;

  select k.id into kyc_id from member.kyc_records k where k.user_id = p_user for update;
  if kyc_id is not null then
    if p_blocked or p_retain_until is not null then
      update member.kyc_records k
         set user_id = null,
             blocked = p_blocked,
             retain_until = p_retain_until,
             nik_hash = case when p_blocked then k.nik_hash end,
             nik_enc = case when p_retain_until is not null then k.nik_enc end,
             enc_key_version = case when p_retain_until is not null then k.enc_key_version end,
             legal_name = case when p_retain_until is not null then k.legal_name end,
             nik_last4 = null,
             doc_ref = null
       where k.id = kyc_id;
      kyc_result := 'tombstoned';
    else
      delete from member.kyc_records k where k.id = kyc_id;
      kyc_result := 'deleted';
      kyc_id := null;
    end if;
  end if;

  if p_blocked then
    update member.payout_methods pm
       set user_id = null, blocked = true, account_no_enc = null, account_last4 = null, account_name = null,
           enc_key_version = null
     where pm.user_id = p_user;
    get diagnostics pm_tombstoned = row_count;
  else
    delete from member.payout_methods pm where pm.user_id = p_user;
    get diagnostics pm_deleted = row_count;
  end if;

  insert into member.audit_logs (actor_id, action, target, after)
  values (p_user, 'account.close', 'user:' || p_user,
          jsonb_build_object('kyc_id', kyc_id, 'kyc', kyc_result, 'blocked', p_blocked, 'retain_until', p_retain_until,
                             'payout_methods_deleted', pm_deleted, 'payout_methods_tombstoned', pm_tombstoned));
  return jsonb_build_object('kyc', kyc_result, 'payout_methods_deleted', pm_deleted,
                            'payout_methods_tombstoned', pm_tombstoned);
end $function$;

CREATE OR REPLACE FUNCTION api.svc_delete_push (
  p_endpoint text
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  delete from member.push_subscriptions where endpoint = p_endpoint;
$function$;

CREATE OR REPLACE FUNCTION api.svc_has_consent (
  p_user uuid,
  p_kind member.consent_kind
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select case
    when p_kind in ('tos_clipper', 'tos_brand', 'privacy') then member.has_current_consent(p_user, p_kind)
    else exists (select 1 from member.consents c
                 where c.user_id = p_user and c.kind = p_kind and c.revoked_at is null)
  end;
$function$;

CREATE OR REPLACE FUNCTION api.svc_kyc (
  p_user_ids uuid[]
)
  RETURNS TABLE (
    user_id         uuid,
    legal_name      text,
    nik_enc         bytea,
    enc_key_version smallint,
    status          member.kyc_status,
    closed          boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select k.user_id, k.legal_name, k.nik_enc, k.enc_key_version, k.status, false
  from member.kyc_records k
  where k.user_id = any (p_user_ids)
  union all
  select u.id, k.legal_name, k.nik_enc, k.enc_key_version, k.status, true
  from unnest(p_user_ids) as u (id)
  join member.audit_logs a on a.target = 'user:' || u.id and a.action = 'account.close'
  join member.kyc_records k on k.id = (a.after ->> 'kyc_id')::uuid
  where k.user_id is null and k.nik_enc is not null and k.retain_until >= current_date;
$function$;

CREATE OR REPLACE FUNCTION api.svc_my_data (
  p_user uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at)
                from auth.users u where u.id = p_user),
    'kyc', (select jsonb_build_object('legal_name', k.legal_name, 'nik_enc', k.nik_enc, 'enc_key_version', k.enc_key_version,
                                      'nik_last4', k.nik_last4, 'doc_ref', k.doc_ref, 'status', k.status,
                                      'reject_reason', k.reject_reason, 'submitted_at', k.submitted_at,
                                      'decided_at', k.decided_at)
            from member.kyc_records k where k.user_id = p_user),
    'payout_methods', coalesce((select jsonb_agg(jsonb_build_object('id', pm.id, 'kind', pm.kind, 'bank_code', pm.bank_code,
                                                                    'account_no_enc', pm.account_no_enc,
                                                                    'enc_key_version', pm.enc_key_version,
                                                                    'account_last4', pm.account_last4,
                                                                    'account_name', pm.account_name,
                                                                    'verified_at', pm.verified_at,
                                                                    'disabled_at', pm.disabled_at,
                                                                    'created_at', pm.created_at) order by pm.created_at)
                                from member.payout_methods pm where pm.user_id = p_user), '[]'::jsonb),
    'recipients', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reward_type_id', r.reward_type_id,
                                                                'data_enc', r.data_enc, 'enc_key_version', r.enc_key_version,
                                                                'updated_at', r.updated_at) order by r.updated_at)
                            from member.recipient_details r where r.user_id = p_user), '[]'::jsonb),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('kind', c.kind, 'version', c.version,
                                                              'granted_at', c.granted_at, 'revoked_at', c.revoked_at)
                                           order by c.granted_at)
                          from member.consents c where c.user_id = p_user), '[]'::jsonb),
    'push_subscriptions', coalesce((select jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'created_at', ps.created_at,
                                                                        'last_used_at', ps.last_used_at) order by ps.created_at)
                                    from member.push_subscriptions ps where ps.user_id = p_user), '[]'::jsonb),
    'platform_roles', coalesce((select jsonb_agg(pr.role order by pr.role)
                                from member.platform_roles pr where pr.user_id = p_user), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION api.svc_payout_methods (
  p_ids uuid[]
)
  RETURNS TABLE (
    id              uuid,
    user_id         uuid,
    kind            text,
    bank_code       text,
    account_no_enc  bytea,
    account_last4   text,
    enc_key_version smallint,
    account_name    text,
    disabled_at     timestamp with time zone,
    blocked         boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select pm.id, pm.user_id, pm.kind, pm.bank_code, pm.account_no_enc, pm.account_last4, pm.enc_key_version,
         pm.account_name, pm.disabled_at, pm.blocked
  from member.payout_methods pm
  where pm.id = any (p_ids);
$function$;

CREATE OR REPLACE FUNCTION api.svc_platform_roles (
  p_user uuid
)
  RETURNS text[]
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce(array_agg(pr.role::text order by pr.role), '{}')
  from member.platform_roles pr
  where pr.user_id = p_user;
$function$;

CREATE OR REPLACE FUNCTION api.svc_push_subscriptions (
  p_user uuid
)
  RETURNS TABLE (
    endpoint    text,
    p256dh      text,
    auth_secret text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select ps.endpoint, ps.p256dh, ps.auth_secret
  from member.push_subscriptions ps
  where ps.user_id = p_user
  order by ps.created_at;
$function$;

CREATE OR REPLACE FUNCTION api.svc_recipients (
  p_ids uuid[]
)
  RETURNS TABLE (
    id              uuid,
    user_id         uuid,
    reward_type_id  uuid,
    data_enc        bytea,
    enc_key_version smallint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select r.id, r.user_id, r.reward_type_id, r.data_enc, r.enc_key_version
  from member.recipient_details r
  where r.id = any (p_ids);
$function$;

CREATE OR REPLACE FUNCTION api.svc_touch_push (
  p_endpoint text
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  update member.push_subscriptions set last_used_at = now() where endpoint = p_endpoint;
$function$;

CREATE OR REPLACE FUNCTION member.custom_access_token_hook (
  event jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (event ->> 'user_id')::uuid;
  roles jsonb;
  kyc text;
  privacy_ok boolean := member.has_current_consent(uid, 'privacy');
begin
  select coalesce(jsonb_agg(pr.role order by pr.role), '[]'::jsonb) into roles
    from member.platform_roles pr where pr.user_id = uid;
  select k.status::text into kyc from member.kyc_records k where k.user_id = uid;
  return jsonb_set(event, '{claims}', (event -> 'claims') || jsonb_build_object(
    'app_roles', roles,
    'kyc', coalesce(kyc, 'none'),
    'consent_ok', jsonb_build_object(
      'clipper', privacy_ok and member.has_current_consent(uid, 'tos_clipper')
                 and exists (select 1 from member.consents c
                             where c.user_id = uid and c.kind = 'age_18_plus' and c.revoked_at is null),
      'brand', privacy_ok and member.has_current_consent(uid, 'tos_brand'))));
end $function$;

CREATE OR REPLACE FUNCTION member.has_current_consent (
  p_user uuid,
  p_kind member.consent_kind
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select exists (
    select 1 from member.consents c
    where c.user_id = p_user and c.kind = p_kind and c.revoked_at is null
      and c.version = (select max(v.version) from member.legal_versions v
                       where v.kind = p_kind and v.published_at <= now()));
$function$;

CREATE OR REPLACE FUNCTION member.invoke_function (
  p_name text,
  p_body jsonb DEFAULT '{}'::jsonb
)
  RETURNS bigint
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'identity_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'identity_secret_key')));
$function$;

CREATE OR REPLACE FUNCTION member.is_admin (
  VARIADIC roles member.platform_role[] DEFAULT '{}'::member.platform_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (
       select 1 from member.platform_roles pr
       where pr.user_id = (select auth.uid())
         and (pr.role = 'admin_super' or cardinality(roles) = 0 or pr.role = any (roles)));
end $function$;

CREATE OR REPLACE FUNCTION member.reject_mutation()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $function$;

ALTER TABLE "member"."consents"
  ADD CONSTRAINT "consents_one_per_version" UNIQUE (user_id, kind, VERSION);

ALTER TABLE "member"."consents"
  ADD CONSTRAINT "consents_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "member"."kyc_records"
  ADD CONSTRAINT "kyc_decision_complete" CHECK (((status = 'pending'::member.kyc_status) = (decided_at IS NULL)));

ALTER TABLE "member"."kyc_records"
  ADD CONSTRAINT "kyc_records_decided_by_fkey" FOREIGN KEY (decided_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE "member"."kyc_records"
  ADD CONSTRAINT "kyc_records_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE "member"."kyc_records"
  ADD CONSTRAINT "kyc_reject_has_reason" CHECK (((status <> 'rejected'::member.kyc_status) OR (reject_reason IS NOT NULL)));

ALTER TABLE "member"."legal_versions"
  ADD CONSTRAINT "legal_versions_kind_check" CHECK ((kind = ANY (ARRAY['tos_clipper'::member.consent_kind, 'tos_brand'::member.consent_kind, 'privacy'::member.consent_kind])));

ALTER TABLE "member"."legal_versions"
  ADD CONSTRAINT "legal_versions_pkey" PRIMARY KEY (kind, VERSION);

ALTER TABLE "member"."payout_methods"
  ADD CONSTRAINT "payout_methods_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE "member"."platform_roles"
  ADD CONSTRAINT "platform_roles_granted_by_fkey" FOREIGN KEY (granted_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE "member"."platform_roles"
  ADD CONSTRAINT "platform_roles_pkey" PRIMARY KEY (user_id, ROLE);

ALTER TABLE "member"."platform_roles"
  ADD CONSTRAINT "platform_roles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "member"."recipient_details"
  ADD CONSTRAINT "recipient_details_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE VIEW "api"."legal_versions" WITH (security_invoker=true) AS  SELECT kind,
    version,
    published_at,
    url
   FROM member.legal_versions;

CREATE VIEW "api"."my_consents" WITH (security_invoker=true) AS  SELECT kind,
    version,
    granted_at,
    revoked_at
   FROM member.consents;

CREATE VIEW "api"."my_kyc" WITH (security_invoker=true) AS  SELECT user_id,
    nik_last4,
    legal_name,
    status,
    reject_reason,
    submitted_at,
    decided_at
   FROM member.kyc_records;

CREATE VIEW "api"."push_subscriptions" WITH (security_invoker=true) AS  SELECT id,
    endpoint,
    created_at,
    last_used_at
   FROM member.push_subscriptions;

CREATE INDEX audit_logs_target_idx ON member.audit_logs USING btree (target, at DESC);

CREATE INDEX consents_user_kind_idx ON member.consents USING btree (user_id, kind, granted_at DESC);

CREATE INDEX kyc_records_decided_by_idx ON member.kyc_records USING btree (decided_by);

CREATE INDEX kyc_records_queue_idx ON member.kyc_records USING btree (submitted_at)
  WHERE ((status = 'pending'::member.kyc_status) AND (user_id IS NOT NULL));

CREATE INDEX payout_methods_user_idx ON member.payout_methods USING btree (user_id);

CREATE INDEX platform_roles_granted_by_idx ON member.platform_roles USING btree (granted_by);

CREATE INDEX push_subscriptions_user_idx ON member.push_subscriptions USING btree (user_id);

CREATE TRIGGER audit_logs_append_only
  BEFORE DELETE OR UPDATE ON member.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION member.reject_mutation();

CREATE POLICY "audit_logs_super_read" ON "member"."audit_logs"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT member.is_admin(VARIADIC ARRAY['admin_super'::member.platform_role]) AS is_admin));

CREATE POLICY "consents_hook" ON "member"."consents"
  FOR SELECT
  TO "supabase_auth_admin"
  USING (true);

CREATE POLICY "consents_own_read" ON "member"."consents"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "kyc_hook" ON "member"."kyc_records"
  FOR SELECT
  TO "supabase_auth_admin"
  USING (true);

CREATE POLICY "kyc_own_read" ON "member"."kyc_records"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "legal_versions_hook" ON "member"."legal_versions"
  FOR SELECT
  TO "supabase_auth_admin"
  USING (true);

CREATE POLICY "legal_versions_read" ON "member"."legal_versions"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "payout_methods_own_read" ON "member"."payout_methods"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "platform_roles_hook" ON "member"."platform_roles"
  FOR SELECT
  TO "supabase_auth_admin"
  USING (true);

CREATE POLICY "platform_roles_super_read" ON "member"."platform_roles"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT member.is_admin(VARIADIC ARRAY['admin_super'::member.platform_role]) AS is_admin));

CREATE POLICY "push_subscriptions_own_delete" ON "member"."push_subscriptions"
  FOR DELETE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "push_subscriptions_own_read" ON "member"."push_subscriptions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "recipient_own_read" ON "member"."recipient_details"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "kyc_docs_own_insert" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'kyc-docs'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

CREATE POLICY "kyc_docs_own_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'kyc-docs'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

CREATE POLICY "kyc_docs_reviewer_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'kyc-docs'::text) AND ( SELECT member.is_admin(VARIADIC ARRAY['admin_moderator'::member.platform_role]) AS is_admin)));

COMMENT ON EXTENSION "pg_cron" IS 'Job scheduler for PostgreSQL';

COMMENT ON EXTENSION "pg_net" IS 'Async HTTP';

REVOKE ALL ON FUNCTION "api"."admin_kyc_decision"(uuid, member.kyc_status, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_decision"(uuid, member.kyc_status, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_kyc_decision"(uuid, member.kyc_status, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_decision"(uuid, member.kyc_status, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."admin_read"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_read"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_read"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_read"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."admin_set_role"(uuid, member.platform_role, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_set_role"(uuid, member.platform_role, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_set_role"(uuid, member.platform_role, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_set_role"(uuid, member.platform_role, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."my_payout_methods"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."my_payout_methods"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."my_payout_methods"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."my_payout_methods"() TO "postgres";

REVOKE ALL ON FUNCTION "api"."record_consent"(member.consent_kind, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."record_consent"(member.consent_kind, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."record_consent"(member.consent_kind, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."record_consent"(member.consent_kind, text, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."save_push_subscription"(text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_push_subscription"(text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_push_subscription"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_push_subscription"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."shared_device_groups"(interval, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."shared_device_groups"(interval, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."shared_device_groups"(interval, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."shared_device_groups"(interval, integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."store_kyc"(uuid, bytea, bytea, text, smallint, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."store_kyc"(uuid, bytea, bytea, text, smallint, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_kyc"(uuid, bytea, bytea, text, smallint, text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_kyc"(uuid, bytea, bytea, text, smallint, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."store_payout_method"(uuid, text, text, bytea, bytea, text, smallint, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."store_payout_method"(uuid, text, text, bytea, bytea, text, smallint, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_payout_method"(uuid, text, text, bytea, bytea, text, smallint, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_payout_method"(uuid, text, text, bytea, bytea, text, smallint, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."store_recipient"(uuid, uuid, bytea, smallint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."store_recipient"(uuid, uuid, bytea, smallint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_recipient"(uuid, uuid, bytea, smallint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_recipient"(uuid, uuid, bytea, smallint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_audit"(uuid, text, text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_audit"(uuid, text, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_audit"(uuid, text, text, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_audit"(uuid, text, text, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_check_ids"(uuid[], uuid[], uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_check_ids"(uuid[], uuid[], uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_check_ids"(uuid[], uuid[], uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_check_ids"(uuid[], uuid[], uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_close_member"(uuid, boolean, date) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_close_member"(uuid, boolean, date) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_close_member"(uuid, boolean, date) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_close_member"(uuid, boolean, date) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_delete_push"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_delete_push"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_delete_push"(text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_delete_push"(text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_has_consent"(uuid, member.consent_kind) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_has_consent"(uuid, member.consent_kind) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_has_consent"(uuid, member.consent_kind) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_has_consent"(uuid, member.consent_kind) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_kyc"(uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_kyc"(uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_kyc"(uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_kyc"(uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_my_data"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_my_data"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_my_data"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_my_data"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_payout_methods"(uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_payout_methods"(uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_payout_methods"(uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_payout_methods"(uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_platform_roles"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_platform_roles"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_platform_roles"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_platform_roles"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_recipients"(uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_recipients"(uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_recipients"(uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_recipients"(uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text) TO "service_role";

REVOKE ALL ON FUNCTION "member"."custom_access_token_hook"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "member"."custom_access_token_hook"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "member"."custom_access_token_hook"(jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "member"."custom_access_token_hook"(jsonb) TO "supabase_auth_admin";

REVOKE ALL ON FUNCTION "member"."has_current_consent"(uuid, member.consent_kind) FROM PUBLIC;

REVOKE ALL ON FUNCTION "member"."has_current_consent"(uuid, member.consent_kind) FROM "postgres";

GRANT EXECUTE ON FUNCTION "member"."has_current_consent"(uuid, member.consent_kind) TO "postgres";

GRANT EXECUTE ON FUNCTION "member"."has_current_consent"(uuid, member.consent_kind) TO "supabase_auth_admin";

REVOKE ALL ON FUNCTION "member"."invoke_function"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "member"."invoke_function"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "member"."invoke_function"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "member"."is_admin"(member.platform_role[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "member"."is_admin"(member.platform_role[]) TO "authenticated";

REVOKE ALL ON FUNCTION "member"."is_admin"(member.platform_role[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "member"."is_admin"(member.platform_role[]) TO "postgres";

REVOKE ALL ON FUNCTION "member"."reject_mutation"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "member"."reject_mutation"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "member"."reject_mutation"() TO "postgres";

GRANT USAGE ON SCHEMA "api" TO "anon", "authenticated", "service_role";

GRANT USAGE ON SCHEMA "member" TO "supabase_auth_admin";

GRANT SELECT ON TABLE "member"."audit_logs" TO "authenticated";

GRANT SELECT ON TABLE "member"."consents" TO "authenticated", "supabase_auth_admin";

GRANT SELECT ("decided_at") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("id") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("legal_name") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("nik_last4") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("reject_reason") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("status") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("submitted_at") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "member"."kyc_records" TO "authenticated";

GRANT SELECT ("status") ON TABLE "member"."kyc_records" TO "supabase_auth_admin";

GRANT SELECT ("user_id") ON TABLE "member"."kyc_records" TO "supabase_auth_admin";

GRANT SELECT ON TABLE "member"."legal_versions" TO "anon", "authenticated", "supabase_auth_admin";

GRANT SELECT ("account_last4") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("account_name") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("bank_code") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("disabled_at") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("id") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("kind") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ("verified_at") ON TABLE "member"."payout_methods" TO "authenticated";

GRANT SELECT ON TABLE "member"."platform_roles" TO "authenticated", "supabase_auth_admin";

GRANT SELECT ("created_at") ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT SELECT ("endpoint") ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT SELECT ("id") ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT SELECT ("last_used_at") ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT DELETE ON TABLE "member"."push_subscriptions" TO "authenticated";

GRANT SELECT ("id") ON TABLE "member"."recipient_details" TO "authenticated";

GRANT SELECT ("reward_type_id") ON TABLE "member"."recipient_details" TO "authenticated";

GRANT SELECT ("updated_at") ON TABLE "member"."recipient_details" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "member"."recipient_details" TO "authenticated";

GRANT SELECT ON TABLE "api"."legal_versions" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."my_consents" TO "authenticated";

GRANT SELECT ON TABLE "api"."my_kyc" TO "authenticated";

GRANT DELETE, SELECT ON TABLE "api"."push_subscriptions" TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" REVOKE ALL ON FUNCTIONS FROM PUBLIC;

SELECT cron.schedule_in_database('fraud-device-scan', '30 * * * *', 'select member.invoke_function(''bridge'', ''{"action":"fraud_device_scan"}'')', 'postgres', NULL, true);
