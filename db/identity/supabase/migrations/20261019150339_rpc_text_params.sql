SET local check_function_bodies = off;

DROP FUNCTION "api"."admin_kyc_decision"(uuid, member.kyc_status, text);

DROP FUNCTION "api"."admin_set_role"(uuid, member.platform_role, boolean);

DROP FUNCTION "api"."record_consent"(member.consent_kind, text, boolean);

DROP FUNCTION "api"."svc_has_consent"(uuid, member.consent_kind);

CREATE OR REPLACE FUNCTION api.admin_kyc_decision (
  p_user_id  uuid,
  p_decision text,
  p_reason   text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  d member.kyc_status := p_decision::member.kyc_status;
begin
  if not member.is_admin('admin_moderator') then
    raise exception 'butuh admin_moderator + aal2' using errcode = '42501';
  end if;
  if d = 'pending' then
    raise exception 'keputusan harus approved atau rejected' using errcode = '22023';
  end if;
  update member.kyc_records
     set status = d,
         reject_reason = case when d = 'rejected' then p_reason end,
         decided_at = now(),
         decided_by = (select auth.uid())
   where user_id = p_user_id and status = 'pending';
  if not found then
    raise exception 'tidak ada KYC menunggu untuk user ini' using errcode = 'P0002';
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'kyc.decide', 'user:' || p_user_id,
          jsonb_build_object('status', d, 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.admin_set_role (
  p_user_id uuid,
  p_role    text,
  p_grant   boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r member.platform_role := p_role::member.platform_role;
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and r = 'admin_super' and not p_grant then
    raise exception 'tidak bisa mencabut admin_super milik sendiri' using errcode = '22023';
  end if;
  if p_grant then
    insert into member.platform_roles (user_id, role, granted_by)
    values (p_user_id, r, (select auth.uid()))
    on conflict (user_id, role) do nothing;
  else
    delete from member.platform_roles where user_id = p_user_id and role = r;
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), case when p_grant then 'role.grant' else 'role.revoke' end, 'user:' || p_user_id,
          jsonb_build_object('role', r));
end $function$;

CREATE OR REPLACE FUNCTION api.record_consent (
  p_kind    text,
  p_version text    DEFAULT NULL::text,
  p_granted boolean DEFAULT true
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  k member.consent_kind := p_kind::member.consent_kind;
  uid uuid := (select auth.uid());
  v text;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  if not p_granted then
    update member.consents set revoked_at = now()
     where user_id = uid and kind = k and revoked_at is null;
    return;
  end if;
  if k in ('tos_clipper', 'tos_brand', 'privacy') then
    select max(lv.version) into v from member.legal_versions lv where lv.kind = k and lv.published_at <= now();
    if v is null or p_version is distinct from v then
      raise exception 'versi % bukan versi terbaru untuk %', p_version, k using errcode = '22023';
    end if;
  else
    v := coalesce(p_version, to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD'));
  end if;
  insert into member.consents (user_id, kind, version) values (uid, k, v)
  on conflict (user_id, kind, version) do update set revoked_at = null, granted_at = now()
    where member.consents.revoked_at is not null;
end $function$;

CREATE OR REPLACE FUNCTION api.svc_has_consent (
  p_user uuid,
  p_kind text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select case
    when p_kind in ('tos_clipper', 'tos_brand', 'privacy') then member.has_current_consent(p_user, p_kind::member.consent_kind)
    else exists (select 1 from member.consents c
                 where c.user_id = p_user and c.kind = p_kind::member.consent_kind and c.revoked_at is null)
  end;
$function$;

REVOKE ALL ON FUNCTION "api"."admin_kyc_decision"(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_decision"(uuid, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_kyc_decision"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_decision"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."admin_set_role"(uuid, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_set_role"(uuid, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_set_role"(uuid, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_set_role"(uuid, text, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."record_consent"(text, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."record_consent"(text, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."record_consent"(text, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."record_consent"(text, text, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_has_consent"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_has_consent"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_has_consent"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_has_consent"(uuid, text) TO "service_role";
