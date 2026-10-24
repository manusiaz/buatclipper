SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.svc_admin_ids (
  p_roles text[]
)
  RETURNS uuid[]
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce(array_agg(distinct pr.user_id order by pr.user_id), '{}')
  from member.platform_roles pr
  where pr.role::text = any (p_roles);
$function$;

REVOKE ALL ON FUNCTION "api"."svc_admin_ids"(text[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_admin_ids"(text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_admin_ids"(text[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_admin_ids"(text[]) TO "service_role";
