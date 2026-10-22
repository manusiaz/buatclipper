SET local check_function_bodies = off;

CREATE SCHEMA "api";

CREATE SCHEMA "bus";

CREATE SCHEMA "market";

CREATE SCHEMA "ops";

CREATE SCHEMA "tracking";

CREATE EXTENSION "pg_cron";

CREATE EXTENSION "pg_net" SCHEMA "extensions";

CREATE TABLE "bus"."handlers" (
  "topic" text         NOT NULL,
  "fn"    regprocedure NOT NULL,
  CONSTRAINT "handlers_pkey" PRIMARY KEY (topic)
);

ALTER TABLE "bus"."handlers"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "bus"."inbox" (
  "id"          uuid                     NOT NULL,
  "source"      text                     NOT NULL,
  "topic"       text                     NOT NULL,
  "received_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "inbox_pkey" PRIMARY KEY (id)
);

ALTER TABLE "bus"."inbox"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "bus"."outbox" (
  "seq"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "target"       text                     NOT NULL,
  "topic"        text                     NOT NULL,
  "payload"      jsonb                    NOT NULL,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  "request_id"   bigint,
  "requested_at" timestamp with time zone,
  "sent_at"      timestamp with time zone,
  "attempts"     integer                  NOT NULL DEFAULT 0,
  "next_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "last_error"   text,
  CONSTRAINT "outbox_id_key" UNIQUE (id),
  CONSTRAINT "outbox_pkey" PRIMARY KEY (seq),
  CONSTRAINT "outbox_target_check" CHECK ((target = ANY (ARRAY['identity'::text, 'creator'::text, 'brand'::text, 'admin'::text]))),
  CONSTRAINT "outbox_topic_check" CHECK ((topic ~ '^[a-z][a-z_]*(\.[a-z][a-z_]*)+$'::text))
);

ALTER TABLE "bus"."outbox"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."settings" (
  "key"        text                     NOT NULL,
  "value"      jsonb                    NOT NULL,
  "updated_by" uuid,
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "settings_key_check" CHECK ((key ~ '^[a-z_]+(\.[a-z_0-9]+)+$'::text)),
  CONSTRAINT "settings_pkey" PRIMARY KEY (key)
);

ALTER TABLE "ops"."settings"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "market"."platform" AS ENUM (
  'tiktok',
  'instagram',
  'youtube',
  'threads',
  'facebook',
  'x'
);

CREATE TYPE "market"."profile_status" AS ENUM (
  'active',
  'suspended',
  'banned',
  'closed'
);

CREATE OR REPLACE FUNCTION api.bus_receive (
  p_source text,
  p_events jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  e jsonb;
  h regprocedure;
  applied int := 0;
  skipped int := 0;
begin
  if jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'invalid:events' using errcode = 'P0001';
  end if;
  for e in select x from jsonb_array_elements(p_events) x loop
    if exists (select 1 from bus.inbox i where i.id = (e ->> 'id')::uuid) then
      skipped := skipped + 1;
      continue;
    end if;
    select bh.fn into h from bus.handlers bh where bh.topic = e ->> 'topic';
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc) using e -> 'payload';
    insert into bus.inbox (id, source, topic) values ((e ->> 'id')::uuid, p_source, e ->> 'topic');
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION bus.emit (
  p_target  text,
  p_topic   text,
  p_payload jsonb
)
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  insert into bus.outbox (target, topic, payload) values (p_target, p_topic, p_payload) returning id;
$function$;

CREATE OR REPLACE FUNCTION bus.me()
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$ select 'creator' $function$;

CREATE OR REPLACE FUNCTION bus.relay()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t text;
  rid bigint;
  asked timestamptz;
  resp record;
  first_ready boolean;
  ids bigint[];
  events jsonb;
  body jsonb;
  ts text;
  url text;
  secret text;
  sent int := 0;
begin
  for t in select distinct o.target from bus.outbox o where o.sent_at is null order by 1 loop
    continue when not pg_try_advisory_xact_lock(hashtextextended('bus_relay:' || t, 0));
    select o.request_id, o.requested_at into rid, asked
      from bus.outbox o where o.target = t and o.sent_at is null and o.request_id is not null order by o.seq limit 1;
    if rid is not null then
      select r.status_code, r.timed_out, r.error_msg, left(r.content, 500) as content into resp
        from net._http_response r where r.id = rid;
      if found and resp.status_code = 200 then
        update bus.outbox set sent_at = now(), last_error = null where target = t and request_id = rid;
      elsif found or asked < now() - interval '60 seconds' then
        update bus.outbox
           set request_id = null, requested_at = null, attempts = attempts + 1,
               next_at = now() + least(interval '1 hour', interval '5 seconds' * power(2, least(attempts, 10))),
               last_error = coalesce(resp.error_msg, case when resp.timed_out then 'timeout' end,
                                     'http ' || resp.status_code || ' ' || coalesce(resp.content, ''), 'no response')
         where target = t and request_id = rid;
        continue;
      else
        continue;  -- masih menunggu jawaban
      end if;
    end if;
    select o.next_at <= now() into first_ready
      from bus.outbox o where o.target = t and o.sent_at is null order by o.seq limit 1;
    continue when not coalesce(first_ready, false);
    select array_agg(b.seq order by b.seq), jsonb_agg(jsonb_build_object('id', b.id, 'topic', b.topic, 'payload', b.payload) order by b.seq)
      into ids, events
      from (select o.seq, o.id, o.topic, o.payload from bus.outbox o
             where o.target = t and o.sent_at is null order by o.seq limit 100) b;
    select ds.decrypted_secret into url from vault.decrypted_secrets ds where ds.name = 'bus_url_' || t;
    select ds.decrypted_secret into secret from vault.decrypted_secrets ds where ds.name = 'bus_secret_' || t;
    if url is null or secret is null then
      update bus.outbox set last_error = 'vault bus_url_/bus_secret_' || t || ' belum diisi' where seq = any (ids);
      continue;
    end if;
    body := jsonb_build_object('v', 1, 'action', 'bus.deliver', 'payload', jsonb_build_object('source', bus.me(), 'events', events));
    ts := floor(extract(epoch from now()))::bigint::text;
    rid := net.http_post(
      url := url || '/functions/v1/bridge',
      body := body,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-bridge-ts', ts, 'x-bridge-from', bus.me(),
                                    'x-bridge-sig', encode(extensions.hmac(ts || '.' || body::text, secret, 'sha256'), 'hex')),
      timeout_milliseconds := 15000);
    update bus.outbox set request_id = rid, requested_at = now() where seq = any (ids);
    sent := sent + cardinality(ids);
  end loop;
  return sent;
end $function$;

CREATE OR REPLACE FUNCTION bus.stuck()
  RETURNS TABLE (
    target     text,
    seq        bigint,
    topic      text,
    attempts   integer,
    last_error text,
    created_at timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select distinct on (o.target) o.target, o.seq, o.topic, o.attempts, o.last_error, o.created_at
    from bus.outbox o where o.sent_at is null and o.attempts >= 5 order by o.target, o.seq;
$function$;

CREATE OR REPLACE FUNCTION ops.has_admin (
  VARIADIC roles text[] DEFAULT '{}'::text[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return ops.iss_ok()
     and coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (select 1 from jsonb_array_elements_text(coalesce((select auth.jwt() -> 'app_roles'), '[]'::jsonb)) r(role)
                 where r.role = 'admin_super' or (cardinality(roles) = 0 and r.role like 'admin\_%') or r.role = any (roles));
end $function$;

CREATE OR REPLACE FUNCTION ops.iss_ok()
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select auth.jwt() ->> 'iss')
                  = (select s.value #>> '{}' from ops.settings s where s.key = 'auth.identity_issuer'), false);
end $function$;

CREATE INDEX outbox_pending_idx ON bus.outbox USING btree (target, seq)
  WHERE (sent_at IS NULL);

CREATE POLICY "settings_admin_read" ON "ops"."settings"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "settings_iss" ON "ops"."settings"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "settings_public_read" ON "ops"."settings"
  FOR SELECT
  TO "anon", "authenticated"
  USING ((key ~~ 'public.%'::text));

COMMENT ON EXTENSION "pg_cron" IS 'Job scheduler for PostgreSQL';

COMMENT ON EXTENSION "pg_net" IS 'Async HTTP';

REVOKE ALL ON FUNCTION "api"."bus_receive"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bus_receive"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bus_receive"(text, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bus_receive"(text, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "bus"."emit"(text, text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."emit"(text, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."emit"(text, text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."me"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."me"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."me"() TO "postgres";

REVOKE ALL ON FUNCTION "bus"."relay"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."relay"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."relay"() TO "postgres";

REVOKE ALL ON FUNCTION "bus"."stuck"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."stuck"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."stuck"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."has_admin"(text[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."has_admin"(text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."has_admin"(text[]) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."iss_ok"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."iss_ok"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."iss_ok"() TO "postgres";

GRANT USAGE ON SCHEMA "api" TO "anon", "authenticated", "service_role";

GRANT SELECT ON TABLE "ops"."settings" TO "anon", "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" REVOKE ALL ON FUNCTIONS FROM PUBLIC;

SELECT cron.schedule_in_database('bus-relay', '5 seconds', 'select bus.relay()', 'postgres', NULL, true);
