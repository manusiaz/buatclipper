SET local check_function_bodies = off;

ALTER TABLE "member"."push_subscriptions"
  DROP CONSTRAINT "push_subscriptions_kind_check";

ALTER TABLE "member"."push_subscriptions"
  DROP CONSTRAINT "push_subscriptions_kind_shape";

DROP FUNCTION "api"."svc_push_subscriptions"(uuid);

DROP FUNCTION "api"."svc_touch_push"(text, text);

ALTER TABLE "member"."push_subscriptions"
  DROP COLUMN "expo_ticket";

CREATE TABLE "member"."push_tickets" (
  "ticket"     text                     NOT NULL,
  "endpoint"   text                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "push_tickets_pkey" PRIMARY KEY (ticket),
  CONSTRAINT "push_tickets_ticket_check" CHECK (((char_length(ticket) >= 1) AND (char_length(ticket) <= 200)))
);

ALTER TABLE "member"."push_tickets"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "member"."session_handoffs" (
  "code_hash"  bytea                    NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "next"       text                     NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "used_at"    timestamp with time zone,
  CONSTRAINT "session_handoffs_code_hash_check" CHECK ((octet_length(code_hash) = 32)),
  CONSTRAINT "session_handoffs_next_check" CHECK (((char_length(next) >= 1) AND (char_length(next) <= 2000))),
  CONSTRAINT "session_handoffs_pkey" PRIMARY KEY (code_hash)
);

ALTER TABLE "member"."session_handoffs"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "member"."push_subscriptions"
  ADD COLUMN "activity_ref" text;

CREATE OR REPLACE FUNCTION api.save_activity_token (
  p_token text,
  p_kind  text,
  p_ref   text DEFAULT NULL::text
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
  if p_kind is null or p_kind not in ('apns_start', 'apns_activity') then
    raise exception 'jenis token harus apns_start atau apns_activity' using errcode = '22023';
  end if;
  insert into member.push_subscriptions (user_id, kind, endpoint, activity_ref)
  values (uid, p_kind, lower(p_token), p_ref)
  on conflict (endpoint) do update set user_id = excluded.user_id, kind = excluded.kind,
    activity_ref = excluded.activity_ref, created_at = now()
  returning id into sid;
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.svc_add_push_tickets (
  p_endpoints text[],
  p_tickets   text[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if coalesce(cardinality(p_endpoints), 0) <> coalesce(cardinality(p_tickets), 0) then
    raise exception 'p_endpoints dan p_tickets harus sama panjang' using errcode = '22023';
  end if;
  insert into member.push_tickets (endpoint, ticket)
  select x.endpoint, x.ticket
  from unnest(p_endpoints, p_tickets) as x (endpoint, ticket)
  where x.ticket is not null
    and exists (select 1 from member.push_subscriptions ps where ps.endpoint = x.endpoint)
  on conflict (ticket) do nothing;
end $function$;

CREATE OR REPLACE FUNCTION api.svc_create_handoff (
  p_user      uuid,
  p_code_hash bytea,
  p_next      text
)
  RETURNS timestamp WITH time zone
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  v_expires timestamptz := now() + interval '60 seconds';
begin
  perform pg_advisory_xact_lock(hashtextextended('session_handoff:' || p_user::text, 0));
  delete from member.session_handoffs h where h.expires_at < now() - interval '1 day';
  if (select count(*) from member.session_handoffs h where h.user_id = p_user and h.expires_at > now()) >= 10 then
    raise exception 'terlalu banyak kode handoff aktif' using errcode = '54000';
  end if;
  insert into member.session_handoffs (code_hash, user_id, next, expires_at) values (p_code_hash, p_user, p_next, v_expires);
  return v_expires;
end $function$;

CREATE OR REPLACE FUNCTION api.svc_due_push_tickets (
  p_limit integer DEFAULT 1000
)
  RETURNS TABLE (
    ticket   text,
    endpoint text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select t.ticket, t.endpoint
  from member.push_tickets t
  where t.created_at <= now() - interval '15 minutes'
  order by t.created_at
  limit greatest(coalesce(p_limit, 1000), 0);
$function$;

CREATE OR REPLACE FUNCTION api.svc_push_subscriptions (
  p_user uuid
)
  RETURNS TABLE (
    kind         text,
    endpoint     text,
    p256dh       text,
    auth_secret  text,
    activity_ref text
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select ps.kind, ps.endpoint, ps.p256dh, ps.auth_secret, ps.activity_ref
  from member.push_subscriptions ps
  where ps.user_id = p_user
  order by ps.created_at;
$function$;

CREATE OR REPLACE FUNCTION api.svc_redeem_handoff (
  p_code_hash bytea
)
  RETURNS TABLE (
    user_id uuid,
    next    text
  )
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  update member.session_handoffs h set used_at = now()
  where h.code_hash = p_code_hash and h.used_at is null and h.expires_at > now()
  returning h.user_id, h.next;
$function$;

CREATE OR REPLACE FUNCTION api.svc_resolve_push_tickets (
  p_tickets        text[],
  p_dead_endpoints text[]
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  removed int;
  resolved int;
  expired int;
begin
  delete from member.push_subscriptions ps where ps.endpoint = any (coalesce(p_dead_endpoints, '{}'));
  get diagnostics removed = row_count;
  delete from member.push_tickets t where t.ticket = any (coalesce(p_tickets, '{}'));
  get diagnostics resolved = row_count;
  delete from member.push_tickets t where t.created_at < now() - interval '24 hours';
  get diagnostics expired = row_count;
  return jsonb_build_object('resolved', resolved, 'removed', removed, 'expired', expired);
end $function$;

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

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_activity_ref_check" CHECK ((activity_ref ~ '^[A-Za-z0-9_-]{1,100}$'::text));

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_kind_check" CHECK ((kind = ANY (ARRAY['webpush'::text, 'expo'::text, 'apns_start'::text, 'apns_activity'::text])));

ALTER TABLE "member"."push_subscriptions"
  ADD CONSTRAINT "push_subscriptions_kind_shape" CHECK ((((kind = 'webpush'::text) AND (endpoint ~ '^https://'::text) AND (p256dh IS NOT NULL) AND (auth_secret IS
    NOT NULL) AND (activity_ref IS NULL)) OR
    ((kind = 'expo'::text) AND (endpoint ~ '^Expo(nent)?PushToken\[[A-Za-z0-9_-]{10,200}\]$'::text) AND (p256dh IS NULL) AND (auth_secret IS NULL) AND (activity_ref IS NULL)) OR
    ((kind = ANY (ARRAY['apns_start'::text, 'apns_activity'::text])) AND (endpoint ~ '^[0-9a-f]+$'::text) AND ((char_length(endpoint) >= 32) AND (char_length(endpoint) <= 512)) AND
    (p256dh IS NULL) AND (auth_secret IS NULL) AND ((activity_ref IS NOT NULL) = (kind = 'apns_activity'::text)))));

ALTER TABLE "member"."push_tickets"
  ADD CONSTRAINT "push_tickets_endpoint_fkey" FOREIGN KEY (endpoint) REFERENCES member.push_subscriptions(endpoint) ON DELETE CASCADE;

ALTER TABLE "member"."session_handoffs"
  ADD CONSTRAINT "session_handoffs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE INDEX push_tickets_created_idx ON member.push_tickets USING btree (created_at);

CREATE INDEX push_tickets_endpoint_idx ON member.push_tickets USING btree (endpoint);

CREATE INDEX session_handoffs_expires_idx ON member.session_handoffs USING btree (expires_at);

CREATE INDEX session_handoffs_user_idx ON member.session_handoffs USING btree (user_id, expires_at);

REVOKE ALL ON FUNCTION "api"."save_activity_token"(text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_activity_token"(text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_activity_token"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_activity_token"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_add_push_tickets"(text[], text[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_add_push_tickets"(text[], text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_add_push_tickets"(text[], text[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_add_push_tickets"(text[], text[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_create_handoff"(uuid, bytea, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_create_handoff"(uuid, bytea, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_create_handoff"(uuid, bytea, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_create_handoff"(uuid, bytea, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_due_push_tickets"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_due_push_tickets"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_due_push_tickets"(integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_due_push_tickets"(integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_push_subscriptions"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_push_subscriptions"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_redeem_handoff"(bytea) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_redeem_handoff"(bytea) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_redeem_handoff"(bytea) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_redeem_handoff"(bytea) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_resolve_push_tickets"(text[], text[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_resolve_push_tickets"(text[], text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_resolve_push_tickets"(text[], text[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_resolve_push_tickets"(text[], text[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_touch_push"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_touch_push"(text) TO "service_role";

SELECT cron.schedule_in_database('push-receipts', '*/30 * * * *', 'select member.invoke_function(''bridge'', ''{"action":"push_receipts"}'')', 'postgres', NULL, true);
