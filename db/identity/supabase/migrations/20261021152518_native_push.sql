SET local check_function_bodies = off;

ALTER TABLE "member"."push_subscriptions"
  DROP CONSTRAINT "push_subscriptions_endpoint_check";

DROP FUNCTION "api"."svc_push_subscriptions"(uuid);

ALTER TABLE "member"."push_subscriptions"
  ADD COLUMN "kind" text NOT NULL DEFAULT 'webpush'::text;

ALTER TABLE "member"."push_subscriptions"
  ALTER COLUMN "auth_secret" DROP NOT NULL;

ALTER TABLE "member"."push_subscriptions"
  ALTER COLUMN "p256dh" DROP NOT NULL;

CREATE OR REPLACE FUNCTION api.save_expo_push_token (
  p_token text
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
  insert into member.push_subscriptions (user_id, kind, endpoint)
  values (uid, 'expo', p_token)
  on conflict (endpoint) do update set user_id = excluded.user_id, created_at = now()
  returning id into sid;
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.svc_push_subscriptions (
  p_user uuid
)
  RETURNS TABLE (
    kind        text,
    endpoint    text,
    p256dh      text,
    auth_secret text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select ps.kind, ps.endpoint, ps.p256dh, ps.auth_secret
  from member.push_subscriptions ps
  where ps.user_id = p_user
  order by ps.created_at;
$function$;

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_kind_check" CHECK ((kind = ANY (ARRAY['webpush'::text, 'expo'::text])));

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_kind_shape" CHECK ((((kind = 'webpush'::text) AND (endpoint ~ '^https://'::text) AND (p256dh IS NOT NULL) AND (auth_secret IS
    NOT NULL)) OR ((kind = 'expo'::text) AND (endpoint ~ '^Expo(nent)?PushToken\[[A-Za-z0-9_-]{10,200}\]$'::text) AND (p256dh IS NULL) AND (auth_secret IS NULL))));

REVOKE ALL ON FUNCTION "api"."save_expo_push_token"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_expo_push_token"(text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_expo_push_token"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_expo_push_token"(text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "service_role";
