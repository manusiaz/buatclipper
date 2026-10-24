SET local check_function_bodies = off;

CREATE TABLE "market"."org_invites" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "org_id"      uuid                     NOT NULL,
  "role"        market.org_role          NOT NULL,
  "token_hash"  bytea                    NOT NULL,
  "expires_at"  timestamp with time zone NOT NULL,
  "accepted_by" uuid,
  "accepted_at" timestamp with time zone,
  "created_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_invites_accept_complete" CHECK (((accepted_by IS NULL) = (accepted_at IS NULL))),
  CONSTRAINT "org_invites_expiry" CHECK ((expires_at > created_at)),
  CONSTRAINT "org_invites_pkey" PRIMARY KEY (id),
  CONSTRAINT "org_invites_token_hash_check" CHECK ((octet_length(token_hash) = 32)),
  CONSTRAINT "org_invites_token_unique" UNIQUE (token_hash)
);

ALTER TABLE "market"."org_invites"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_links" (
  "agency_org_id" uuid                     NOT NULL,
  "client_org_id" uuid                     NOT NULL,
  "approved_by"   uuid,
  "approved_at"   timestamp with time zone,
  "revoked_at"    timestamp with time zone,
  "created_at"    timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_links_approval_complete" CHECK (((approved_by IS NULL) = (approved_at IS NULL))),
  CONSTRAINT "org_links_not_self" CHECK ((agency_org_id <> client_org_id)),
  CONSTRAINT "org_links_pkey" PRIMARY KEY (agency_org_id, client_org_id)
);

ALTER TABLE "market"."org_links"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_members" (
  "org_id"     uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "role"       market.org_role          NOT NULL,
  "added_by"   uuid,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_members_pkey" PRIMARY KEY (org_id, user_id)
);

ALTER TABLE "market"."org_members"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."organizations" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "name"        text                     NOT NULL,
  "org_type"    text                     NOT NULL,
  "legal_name"  text,
  "npwp"        text,
  "address"     text,
  "is_agency"   boolean                  NOT NULL DEFAULT false,
  "status"      market.org_status        NOT NULL DEFAULT 'pending_verification'::market.org_status,
  "verified_by" uuid,
  "verified_at" timestamp with time zone,
  "created_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "updated_at"  timestamp with time zone,
  CONSTRAINT "organizations_name_check" CHECK (((char_length(name) >= 2) AND (char_length(name) <= 100))),
  CONSTRAINT "organizations_npwp_check" CHECK ((npwp ~ '^[0-9]{15,16}$'::text)),
  CONSTRAINT "organizations_org_type_check" CHECK ((org_type = ANY (ARRAY['badan'::text, 'perorangan'::text]))),
  CONSTRAINT "organizations_perorangan_no_pii" CHECK (((org_type = 'badan'::text) OR ((legal_name IS NULL) AND (npwp IS NULL) AND (address IS NULL)))),
  CONSTRAINT "organizations_pkey" PRIMARY KEY (id),
  CONSTRAINT "organizations_verified_complete" CHECK (((status <> 'verified'::market.org_status) OR ((verified_at IS NOT NULL) AND (verified_by IS NOT NULL))))
);

ALTER TABLE "market"."organizations"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."profiles" (
  "id"              uuid                     NOT NULL,
  "username"        text,
  "display_name"    text,
  "avatar_path"     text,
  "suspended_until" timestamp with time zone,
  CONSTRAINT "profiles_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."profiles"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."audit_logs" (
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

ALTER TABLE "ops"."audit_logs"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "market"."profile_status" AS ENUM (
  'active',
  'suspended',
  'banned',
  'closed'
);

ALTER TABLE "market"."profiles"
  ADD COLUMN "status" market.profile_status NOT NULL DEFAULT 'active'::market.profile_status;

CREATE OR REPLACE FUNCTION api.accept_org_invite (
  p_token text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  inv market.org_invites;
begin
  select * into inv from market.org_invites where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8')) for update;
  if inv.id is null then
    perform market.fail('not_found:invite', 'link undangan tidak dikenal', 'P0002');
  end if;
  if exists (select 1 from market.org_members m where m.org_id = inv.org_id and m.user_id = uid) then
    return inv.org_id;
  end if;
  if inv.accepted_at is not null then
    perform market.fail('invite_used', 'link undangan sudah dipakai');
  end if;
  if inv.expires_at <= now() then
    perform market.fail('invite_expired', 'link undangan kedaluwarsa; minta link baru');
  end if;
  if exists (select 1 from market.profiles p where p.id = uid and p.status <> 'active') then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  perform market.ensure_member_profile(uid);
  insert into market.org_members (org_id, user_id, role, added_by) values (inv.org_id, uid, inv.role, inv.created_by);
  update market.org_invites set accepted_by = uid, accepted_at = now() where id = inv.id;
  return inv.org_id;
end $function$;

CREATE OR REPLACE FUNCTION api.create_org (
  p_name       text,
  p_org_type   text,
  p_legal_name text    DEFAULT NULL::text,
  p_npwp       text    DEFAULT NULL::text,
  p_address    text    DEFAULT NULL::text,
  p_is_agency  boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  oid uuid;
  npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
begin
  if not coalesce((select (auth.jwt() -> 'consent_ok' ->> 'brand')::boolean), false) then
    perform market.fail('consent_required:brand', 'setujui ToS brand dulu (accounts onboarding?role=brand)');
  end if;
  -- Replika profil (pemilik di project profil); belum tereplika = baru onboarding, bukan diblokir.
  if exists (select 1 from market.profiles p where p.id = uid
              and not (p.status = 'active' or (p.status = 'suspended' and p.suspended_until <= now()))) then
    perform market.fail('not_eligible:profile_inactive', 'profil belum ada atau tidak aktif');
  end if;
  perform market.ensure_member_profile(uid);
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if p_org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if npwp is null or npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
    if nullif(btrim(p_address), '') is null then  -- B1.4 / F-B01: alamat badan dipakai di faktur
      perform market.fail('invalid:address', 'badan usaha wajib alamat');
    end if;
  elsif p_org_type = 'perorangan' then
    if coalesce(p_legal_name, p_npwp, p_address) is not null then
      perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
    end if;
  else
    perform market.fail('invalid:org_type', coalesce(p_org_type, 'null'));
  end if;
  insert into market.organizations (name, org_type, legal_name, npwp, address, is_agency, created_by)
  values (btrim(p_name), p_org_type, nullif(btrim(p_legal_name), ''), npwp, nullif(btrim(p_address), ''),
          coalesce(p_is_agency, false), uid)
  returning id into oid;
  insert into market.org_members (org_id, user_id, role, added_by) values (oid, uid, 'brand_owner', uid);
  return oid;
end $function$;

CREATE OR REPLACE FUNCTION api.create_org_invite (
  p_org  uuid,
  p_role text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r market.org_role := p_role::market.org_role;
  uid uuid := market.session_uid();
  tok text;
begin
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if r is null then
    perform market.fail('invalid:role', 'role wajib');
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.org_invites (org_id, role, token_hash, expires_at, created_by)
  values (p_org, r, sha256(convert_to(tok, 'UTF8')), now() + interval '7 days', uid);
  return tok;
end $function$;

CREATE OR REPLACE FUNCTION api.invite_preview (
  p_token text
)
  RETURNS TABLE (
    org_name  text,
    is_agency boolean,
    role      text,
    expired   boolean,
    used      boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select o.name, o.is_agency, i.role::text, i.expires_at <= now(), i.accepted_at is not null
    from market.org_invites i join market.organizations o on o.id = i.org_id
   where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
$function$;

CREATE OR REPLACE FUNCTION api.link_agency (
  p_agency uuid,
  p_client uuid,
  p_action text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  l market.org_links;
begin
  select * into l from market.org_links where agency_org_id = p_agency and client_org_id = p_client for update;
  if p_action = 'request' then
    if not market.is_direct_member(p_agency, uid, 'brand_owner', 'brand_manager') then
      perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org agency', '42501');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_agency and o.is_agency) then
      perform market.fail('not_agency', 'org ini bukan agency');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_client) or p_client = p_agency then
      perform market.fail('not_found:org', null, 'P0002');
    end if;
    if l.agency_org_id is not null and l.revoked_at is null then
      perform market.fail('already_linked', case when l.approved_at is null then 'menunggu persetujuan klien' else 'sudah tertaut' end);
    end if;
    insert into market.org_links (agency_org_id, client_org_id) values (p_agency, p_client)
    on conflict (agency_org_id, client_org_id) do update
      set approved_by = null, approved_at = null, revoked_at = null, created_at = now();
    perform market.notify_org(p_client, array['brand_owner']::market.org_role[], 'agency.link_requested',
                              jsonb_build_object('agency_org_id', p_agency,
                                                 'agency_org_name', (select o.name from market.organizations o where o.id = p_agency)));
  elsif p_action = 'approve' then
    if not market.is_direct_member(p_client, uid, 'brand_owner') then
      perform market.fail('auth:forbidden', 'butuh brand_owner org klien', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null or l.approved_at is not null then
      perform market.fail('invalid_state:link', 'tidak ada permintaan yang menunggu');
    end if;
    update market.org_links set approved_by = uid, approved_at = now()
     where agency_org_id = p_agency and client_org_id = p_client;
    perform market.notify_org(p_agency, array['brand_owner', 'brand_manager']::market.org_role[], 'agency.link_approved',
                              jsonb_build_object('client_org_id', p_client,
                                                 'client_org_name', (select o.name from market.organizations o where o.id = p_client)));
  elsif p_action in ('revoke', 'reject') then
    if not (market.is_direct_member(p_client, uid, 'brand_owner') or market.is_direct_member(p_agency, uid, 'brand_owner')) then
      perform market.fail('auth:forbidden', 'butuh brand_owner klien atau agency', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null then
      perform market.fail('invalid_state:link', 'tautan tidak aktif');
    end if;
    update market.org_links set revoked_at = now() where agency_org_id = p_agency and client_org_id = p_client;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
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
  member_id uuid;
  member_role market.org_role;
  old_role market.org_role;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_super aal2', '42501');
  end if;
  select * into o from market.organizations where id = p_org;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_action = 'verify' then
    perform market.decide_org(o.id, 'approve', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'reject' then
    perform market.decide_org(o.id, 'reject', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'suspend' then
    if nullif(btrim(prm ->> 'reason'), '') is null then
      perform market.fail('invalid:reason', 'suspend wajib alasan');
    end if;
    update market.organizations set status = 'suspended' where id = o.id;
    perform market.notify_org(o.id, null, 'org.suspended', jsonb_build_object('reason', prm ->> 'reason', 'message', prm ->> 'message'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.suspend', 'org:' || o.id, jsonb_build_object('status', o.status),
            jsonb_build_object('status', 'suspended', 'reason', prm ->> 'reason'));
  elsif p_action = 'add_member' then
    member_id := (prm ->> 'user_id')::uuid;
    member_role := coalesce((prm ->> 'role')::market.org_role, 'brand_owner');
    if member_id is null then
      perform market.fail('invalid:user_id', 'user_id identity wajib');
    end if;
    perform market.ensure_member_profile(member_id, prm ->> 'username', prm ->> 'display_name');
    select m.role into old_role from market.org_members m where m.org_id = o.id and m.user_id = member_id;
    insert into market.org_members (org_id, user_id, role, added_by) values (o.id, member_id, member_role, uid)
    on conflict (org_id, user_id) do update set role = excluded.role;
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.add_member', 'org:' || o.id, jsonb_build_object('user_id', member_id, 'role', old_role),
            jsonb_build_object('user_id', member_id, 'role', member_role));
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.manage_team (
  p_org    uuid,
  p_action text,
  p_target uuid,
  p_role   text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  m market.org_members;
  r market.org_role;
begin
  perform 1 from market.organizations where id = p_org for no key update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if p_action = 'revoke_invite' then
    delete from market.org_invites where id = p_target and org_id = p_org and accepted_at is null;
    if not found then
      perform market.fail('not_found:invite', null, 'P0002');
    end if;
  elsif p_action in ('set_role', 'remove') then
    select * into m from market.org_members where org_id = p_org and user_id = p_target;
    if m.user_id is null then
      perform market.fail('not_found:member', null, 'P0002');
    end if;
    if p_action = 'set_role' then
      r := p_role::market.org_role;
      if r is null then
        perform market.fail('invalid:role', 'role wajib');
      end if;
    end if;
    if m.role = 'brand_owner' and r is distinct from 'brand_owner'
       and not exists (select 1 from market.org_members o where o.org_id = p_org and o.role = 'brand_owner' and o.user_id <> m.user_id) then
      perform market.fail('last_owner', 'org harus punya minimal satu brand_owner');
    end if;
    if p_action = 'remove' then
      delete from market.org_members where org_id = p_org and user_id = m.user_id;
    else
      update market.org_members set role = r where org_id = p_org and user_id = m.user_id;
    end if;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.team.' || p_action, 'org:' || p_org,
          case when m.user_id is not null then jsonb_build_object('user_id', m.user_id, 'role', m.role) else jsonb_build_object('invite_id', p_target) end,
          case when p_action = 'set_role' then jsonb_build_object('role', r) end);
end $function$;

CREATE OR REPLACE FUNCTION api.update_org (
  p_org        uuid,
  p_name       text,
  p_legal_name text DEFAULT NULL::text,
  p_npwp       text DEFAULT NULL::text,
  p_address    text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  o market.organizations;
  v_npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
  legal_changed boolean;
begin
  select * into o from market.organizations where id = p_org for no key update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if o.org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if v_npwp is null or v_npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
    if nullif(btrim(p_address), '') is null then
      perform market.fail('invalid:address', 'badan usaha wajib alamat');
    end if;
  elsif coalesce(p_legal_name, p_npwp, p_address) is not null then
    perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
  end if;
  legal_changed := o.org_type = 'badan' and (o.legal_name is distinct from btrim(p_legal_name) or o.npwp is distinct from v_npwp
                                             or o.address is distinct from btrim(p_address));
  update market.organizations
     set name = btrim(p_name), legal_name = nullif(btrim(p_legal_name), ''), npwp = v_npwp, address = nullif(btrim(p_address), ''),
         updated_at = now(),
         status = case when legal_changed and status = 'verified' then 'pending_verification' else status end,
         verified_at = case when legal_changed and status = 'verified' then null else verified_at end,
         verified_by = case when legal_changed and status = 'verified' then null else verified_by end
   where id = o.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.update', 'org:' || o.id,
          jsonb_build_object('name', o.name, 'legal_name', o.legal_name, 'npwp', o.npwp, 'address', o.address, 'status', o.status),
          jsonb_build_object('name', btrim(p_name), 'legal_name', nullif(btrim(p_legal_name), ''), 'npwp', v_npwp,
                             'address', nullif(btrim(p_address), ''), 'reverify', legal_changed));
end $function$;

CREATE OR REPLACE FUNCTION market.decide_org (
  p_org      uuid,
  p_decision text,
  p_actor    uuid,
  p_reason   text,
  p_message  text,
  p_note     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  o market.organizations;
begin
  select * into o from market.organizations where id = p_org for update;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_decision = 'approve' then
    update market.organizations set status = 'verified', verified_by = p_actor, verified_at = now() where id = o.id;
  elsif p_decision = 'reject' then
    if nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if o.status = 'verified' then
      perform market.fail('invalid_state:verified', 'org sudah verified; pakai suspend');
    end if;
  else
    perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
  end if;
  perform bus.emit('admin', 'review.decision', jsonb_build_object('target_type', 'org', 'target_id', o.id, 'actor_id', p_actor,
                    'decision', p_decision, 'reason_code', p_reason, 'message', p_message, 'note', p_note));
  perform market.notify_org(o.id, null, case p_decision when 'approve' then 'org.verified' else 'org.rejected' end,
                            jsonb_build_object('reason', p_reason, 'message', p_message));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (p_actor, case p_decision when 'approve' then 'org.verify' else 'org.reject' end, 'org:' || o.id,
          jsonb_build_object('status', o.status),
          jsonb_build_object('status', case p_decision when 'approve' then 'verified' else o.status::text end, 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION market.ensure_member_profile (
  p_user         uuid,
  p_username     text DEFAULT NULL::text,
  p_display_name text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform bus.emit('admin', 'profile.ensure', jsonb_build_object('user_id', p_user, 'username', p_username, 'display_name', p_display_name));
end $function$;

CREATE OR REPLACE FUNCTION market.is_direct_member (
  p_org    uuid,
  p_user   uuid,
  VARIADIC p_roles market.org_role[] DEFAULT '{}'::market.org_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform 1 from market.org_members m where m.org_id = p_org and m.user_id = p_user
                                         and (cardinality(p_roles) = 0 or m.role = any (p_roles))
     for share;
  return found;
end $function$;

CREATE OR REPLACE FUNCTION market.keep_one_owner()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner')
     and not exists (select 1 from market.org_members m
                     where m.org_id = old.org_id and m.role = 'brand_owner' and m.user_id <> old.user_id) then
    raise exception 'org harus punya minimal satu brand_owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $function$;

CREATE OR REPLACE FUNCTION market.notify_org (
  p_org     uuid,
  p_roles   market.org_role[],
  p_event   text,
  p_payload jsonb             DEFAULT '{}'::jsonb
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
  body jsonb := coalesce(p_payload, '{}')
                || jsonb_build_object('org_id', p_org, 'org_name', (select o.name from market.organizations o where o.id = p_org));
begin
  for r in
    select m.user_id from market.org_members m
     where m.org_id = p_org and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
    union
    select m.user_id from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
     where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null
       and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
  loop
    perform ops.enqueue_notification(r.user_id, p_event, body);
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.on_owner_lost()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner') then
    delete from market.org_invites where org_id = old.org_id and created_by = old.user_id and accepted_at is null;
    perform bus.emit('admin', 'org.owner_lost', jsonb_build_object('org_id', old.org_id, 'user_id', old.user_id,
                                                                    'actor_id', (select auth.uid())));
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION ops.enqueue_notification (
  p_user    uuid,
  p_event   text,
  p_payload jsonb   DEFAULT '{}'::jsonb,
  p_email   boolean DEFAULT true
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform bus.emit('admin', 'notify.user', jsonb_build_object('user_id', p_user, 'event', p_event, 'payload', coalesce(p_payload, '{}'),
                                                               'email', p_email));
  return null;
end $function$;

CREATE OR REPLACE FUNCTION ops.forward_audit()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform bus.emit('admin', 'audit.log', to_jsonb(new) - 'id');
  return null;
end $function$;

CREATE OR REPLACE FUNCTION ops.reject_mutation()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $function$;

ALTER TABLE "market"."org_invites"
  ADD CONSTRAINT "org_invites_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_agency_org_id_fkey" FOREIGN KEY (agency_org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_client_org_id_fkey" FOREIGN KEY (client_org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_members"
  ADD CONSTRAINT "org_members_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

CREATE VIEW "api"."org_invites" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    role,
    expires_at,
    accepted_by,
    accepted_at,
    created_by,
    created_at
   FROM market.org_invites;

CREATE VIEW "api"."org_links" WITH (security_invoker=true) AS  SELECT agency_org_id,
    client_org_id,
    approved_by,
    approved_at,
    revoked_at,
    created_at
   FROM market.org_links;

CREATE VIEW "api"."org_members" WITH (security_invoker=true) AS  SELECT org_id,
    user_id,
    role,
    created_at
   FROM market.org_members;

CREATE VIEW "api"."organizations" WITH (security_invoker=true) AS  SELECT id,
    name,
    org_type,
    legal_name,
    npwp,
    address,
    is_agency,
    status,
    verified_at,
    created_at,
    updated_at
   FROM market.organizations;

CREATE VIEW "api"."profiles" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path
   FROM market.profiles;

CREATE INDEX org_invites_accepted_by_idx ON market.org_invites USING btree (accepted_by);

CREATE INDEX org_invites_created_by_idx ON market.org_invites USING btree (created_by);

CREATE INDEX org_invites_org_idx ON market.org_invites USING btree (org_id);

CREATE INDEX org_links_client_idx ON market.org_links USING btree (client_org_id);

CREATE INDEX org_members_user_idx ON market.org_members USING btree (user_id);

CREATE INDEX audit_logs_actor_idx ON ops.audit_logs USING btree (actor_id, at DESC);

CREATE INDEX audit_logs_target_idx ON ops.audit_logs USING btree (target, at DESC);

CREATE TRIGGER org_links_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.org_links
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:approved_by,approved_at,revoked_at,created_at', 'creator:approved_at,revoked_at,created_at');

CREATE TRIGGER org_members_keep_owner
  BEFORE DELETE OR UPDATE ON market.org_members
  FOR EACH ROW
  EXECUTE FUNCTION market.keep_one_owner();

CREATE TRIGGER org_members_owner_lost
  AFTER DELETE OR UPDATE ON market.org_members
  FOR EACH ROW
  EXECUTE FUNCTION market.on_owner_lost();

CREATE TRIGGER org_members_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.org_members
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:role,added_by,created_at', 'creator:role,created_at');

CREATE TRIGGER organizations_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.organizations
  FOR EACH ROW
  EXECUTE FUNCTION
    bus.replicate('admin:name,org_type,legal_name,npwp,address,is_agency,status,verified_by,verified_at,created_by,created_at,updated_at',
    'creator:name,is_agency,status,verified_at,created_at');

CREATE TRIGGER audit_logs_append_only
  BEFORE DELETE OR UPDATE ON ops.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE TRIGGER audit_logs_forward
  AFTER INSERT ON ops.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION ops.forward_audit();

CREATE POLICY "org_invites_iss" ON "market"."org_invites"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_invites_owner_read" ON "market"."org_invites"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(org_invites.org_id, VARIADIC ARRAY['brand_owner'::market.org_role]) AS is_org_member));

CREATE POLICY "org_links_admin_read" ON "market"."org_links"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "org_links_iss" ON "market"."org_links"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_links_party_read" ON "market"."org_links"
  FOR SELECT
  TO "authenticated"
  USING
    ((( SELECT ops.is_org_member(org_links.agency_org_id) AS is_org_member) OR ( SELECT ops.is_org_member(org_links.client_org_id, VARIADIC ARRAY['brand_owner'::market.org_role])
    AS is_org_member)));

CREATE POLICY "org_members_admin_read" ON "market"."org_members"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "org_members_iss" ON "market"."org_members"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_members_same_org_read" ON "market"."org_members"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(org_members.org_id) AS is_org_member));

CREATE POLICY "organizations_admin_read" ON "market"."organizations"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "organizations_iss" ON "market"."organizations"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "organizations_member_read" ON "market"."organizations"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(organizations.id) AS is_org_member));

CREATE POLICY "profiles_iss" ON "market"."profiles"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "profiles_public_read" ON "market"."profiles"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

REVOKE ALL ON FUNCTION "api"."accept_org_invite"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."accept_org_invite"(text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."accept_org_invite"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."accept_org_invite"(text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."invite_preview"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."invite_preview"(text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."invite_preview"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."invite_preview"(text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."link_agency"(uuid, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."link_agency"(uuid, uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."link_agency"(uuid, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."link_agency"(uuid, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."manage_org"(uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."manage_org"(uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."manage_org"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."manage_org"(uuid, text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."update_org"(uuid, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."update_org"(uuid, text, text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."update_org"(uuid, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."update_org"(uuid, text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) TO "postgres";

REVOKE ALL ON FUNCTION "market"."keep_one_owner"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."keep_one_owner"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."keep_one_owner"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."on_owner_lost"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."on_owner_lost"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."on_owner_lost"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."forward_audit"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."forward_audit"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."forward_audit"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."reject_mutation"() TO "postgres";

GRANT SELECT ("accepted_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("accepted_by") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("created_by") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("expires_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("id") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("org_id") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("role") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ON TABLE "market"."org_links" TO "authenticated";

GRANT SELECT ON TABLE "market"."org_members" TO "authenticated";

GRANT SELECT ON TABLE "market"."organizations" TO "authenticated";

GRANT SELECT ("avatar_path") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("display_name") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("id") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("username") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("avatar_path") ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ("display_name") ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ("id") ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ("username") ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_invites" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_links" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_members" TO "authenticated";

GRANT SELECT ON TABLE "api"."organizations" TO "authenticated";

GRANT SELECT ON TABLE "api"."profiles" TO "anon", "authenticated";
