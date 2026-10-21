SET local check_function_bodies = off;

DROP FUNCTION "api"."svc_push_subscriptions"(uuid);

DROP FUNCTION "api"."svc_touch_push"(text);

ALTER TABLE "member"."push_subscriptions"
  ADD COLUMN "expo_ticket" text;

CREATE OR REPLACE FUNCTION api.svc_push_subscriptions (
  p_user uuid
)
  RETURNS TABLE (
    kind        text,
    endpoint    text,
    p256dh      text,
    auth_secret text,
    expo_ticket text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select ps.kind, ps.endpoint, ps.p256dh, ps.auth_secret, ps.expo_ticket
  from member.push_subscriptions ps
  where ps.user_id = p_user
  order by ps.created_at;
$function$;

CREATE OR REPLACE FUNCTION api.svc_touch_push (
  p_endpoint text,
  p_ticket   text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  update member.push_subscriptions set last_used_at = now(), expo_ticket = coalesce(p_ticket, expo_ticket)
  where endpoint = p_endpoint;
$function$;

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text, text) TO "service_role";
