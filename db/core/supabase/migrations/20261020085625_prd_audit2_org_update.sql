SET local check_function_bodies = off;

DROP VIEW "api"."organizations";

ALTER TABLE "market"."organizations"
  ADD COLUMN "updated_at" timestamp WITH time zone;

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
  if not exists (select 1 from market.profiles p where p.id = uid and p.status = 'active') then
    perform market.fail('not_eligible:profile_inactive', 'profil belum ada atau tidak aktif');
  end if;
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
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  select * into o from market.organizations where id = p_org for update;
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

CREATE VIEW "api"."organizations" WITH (security_invoker=true) AS  SELECT id,
    name,
    org_type,
    legal_name,
    npwp,
    address,
    is_agency,
    fee_rule_id,
    status,
    verified_at,
    created_at,
    updated_at
   FROM market.organizations;

REVOKE ALL ON FUNCTION "api"."update_org"(uuid, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."update_org"(uuid, text, text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."update_org"(uuid, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."update_org"(uuid, text, text, text, text) TO "postgres";

GRANT SELECT ON TABLE "api"."organizations" TO "authenticated";
