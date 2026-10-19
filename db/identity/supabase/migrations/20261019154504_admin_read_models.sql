SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.admin_kyc_queue (
  p_status text    DEFAULT 'pending'::text,
  p_limit  integer DEFAULT 100
)
  RETURNS TABLE (
    user_id       uuid,
    status        text,
    submitted_at  timestamp with time zone,
    decided_at    timestamp with time zone,
    reject_reason text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not member.is_admin('admin_moderator') then
    raise exception 'butuh admin_moderator + aal2' using errcode = '42501';
  end if;
  return query
    select k.user_id, k.status::text, k.submitted_at, k.decided_at, k.reject_reason
      from member.kyc_records k
     where k.user_id is not null and k.status = p_status::member.kyc_status
     order by case when k.status = 'pending' then k.submitted_at end, k.decided_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $function$;

CREATE OR REPLACE FUNCTION api.admin_list_roles()
  RETURNS TABLE (
    user_id    uuid,
    email      text,
    roles      text[],
    granted_at timestamp with time zone
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  return query
    select pr.user_id, u.email::text, array_agg(pr.role::text order by pr.role::text), min(pr.granted_at)
      from member.platform_roles pr join auth.users u on u.id = pr.user_id
     group by pr.user_id, u.email
     order by u.email;
end $function$;

CREATE VIEW "api"."audit_logs" WITH (security_invoker=true) AS  SELECT id,
    actor_id,
    action,
    target,
    before,
    after,
    at
   FROM member.audit_logs;

CREATE VIEW "api"."my_recipients" WITH (security_invoker=true) AS  SELECT id,
    reward_type_id,
    updated_at
   FROM member.recipient_details;

REVOKE ALL ON FUNCTION "api"."admin_kyc_queue"(text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_queue"(text, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_kyc_queue"(text, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_kyc_queue"(text, integer) TO "postgres";

REVOKE ALL ON FUNCTION "api"."admin_list_roles"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_list_roles"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_list_roles"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_list_roles"() TO "postgres";

GRANT SELECT ON TABLE "api"."audit_logs" TO "authenticated";

GRANT SELECT ON TABLE "api"."my_recipients" TO "authenticated";
