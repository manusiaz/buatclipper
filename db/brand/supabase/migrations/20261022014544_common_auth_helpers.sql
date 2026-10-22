SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.fail (
  p_code    text,
  p_detail  text DEFAULT NULL::text,
  p_errcode text DEFAULT 'P0001'::text
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception using message = p_code, errcode = p_errcode, detail = coalesce(p_detail, '');
end $function$;

CREATE OR REPLACE FUNCTION market.session_uid()
  RETURNS uuid
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  return uid;
end $function$;

CREATE OR REPLACE FUNCTION ops.is_org_member (
  p_org    uuid,
  VARIADIC roles market.org_role[] DEFAULT '{}'::market.org_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r text := ops.org_role(p_org)::text;
begin
  return r is not null and (cardinality(roles) = 0 or r = any (roles::text[]));
end $function$;

CREATE OR REPLACE FUNCTION ops.org_role (
  p_org uuid
)
  RETURNS market.org_role
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce(
    (select m.role from market.org_members m where m.org_id = p_org and m.user_id = (select auth.uid())),
    (select m.role from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
      where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null and m.user_id = (select auth.uid())
      order by array_position(enum_range(null::market.org_role), m.role) limit 1));
end $function$;

REVOKE ALL ON FUNCTION "market"."fail"(text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."fail"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."fail"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."session_uid"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."session_uid"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."session_uid"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."has_admin"(text[]) FROM "authenticated";

GRANT EXECUTE ON FUNCTION "ops"."has_admin"(text[]) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."iss_ok"() FROM "authenticated";

GRANT EXECUTE ON FUNCTION "ops"."iss_ok"() TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."org_role"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."org_role"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."org_role"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."org_role"(uuid) TO "postgres";
