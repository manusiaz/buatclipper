SET local check_function_bodies = off;

CREATE TABLE "ops"."bus_peers" (
  "source"    text                     NOT NULL,
  "pinged_at" timestamp with time zone NOT NULL DEFAULT now(),
  "stuck"     jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  CONSTRAINT "bus_peers_pkey" PRIMARY KEY (source),
  CONSTRAINT "bus_peers_source_check" CHECK ((source = ANY (ARRAY['creator'::text, 'brand'::text]))),
  CONSTRAINT "bus_peers_stuck_check" CHECK ((jsonb_typeof(stuck) = 'array'::text))
);

ALTER TABLE "ops"."bus_peers"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION api.health()
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select jsonb_build_object('db', bus.me(), 'at', now(),
    'outbox', coalesce((select jsonb_object_agg(x.target, jsonb_build_object('pending', x.pending, 'stuck', x.stuck, 'oldest_pending_at', x.oldest))
                          from (select o.target, count(*) as pending, count(*) filter (where o.attempts >= 5) as stuck, min(o.created_at) as oldest
                                  from bus.outbox o where o.sent_at is null group by o.target) x), '{}'),
    'last_received', (select jsonb_object_agg(src, (select max(i.received_at) from bus.inbox i where i.source = src))
                        from unnest(array['creator', 'brand', 'admin']) src where src <> bus.me()));
$function$;

CREATE OR REPLACE FUNCTION bus.ping()
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(), 'at', now(),
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')));
$function$;

CREATE OR REPLACE FUNCTION bus_in.bus_ping (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into ops.bus_peers (source, pinged_at, stuck)
  select p ->> 'source', coalesce((p ->> 'at')::timestamptz, now()),
         case when jsonb_typeof(p -> 'stuck') = 'array' then p -> 'stuck' else '[]' end
   where p ->> 'source' in ('creator', 'brand')
  on conflict (source) do update set pinged_at = greatest(ops.bus_peers.pinged_at, excluded.pinged_at), stuck = excluded.stuck;
$function$;

CREATE OR REPLACE FUNCTION ops.watch_bus()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  late jsonb;
  peer_stuck jsonb;
  own_stuck jsonb;
begin
  select jsonb_agg(p.source order by p.source) into late from ops.bus_peers p where p.pinged_at < now() - interval '15 minutes';
  select jsonb_agg(jsonb_build_object('source', p.source) || e.value) into peer_stuck
    from ops.bus_peers p cross join lateral jsonb_array_elements(p.stuck) e;
  select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts)) into own_stuck from bus.stuck() s;
  if late is not null or peer_stuck is not null or own_stuck is not null then
    perform ops.raise_alert('bus.stuck', 'critical', jsonb_strip_nulls(jsonb_build_object('late', late, 'peer_stuck', peer_stuck,
                                                                                         'admin_stuck', own_stuck)), interval '1 hour');
  end if;
end $function$;

CREATE INDEX inbox_source_idx ON bus.inbox USING btree (source, received_at DESC);

CREATE POLICY "bus_peers_admin_read" ON "ops"."bus_peers"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "bus_peers_iss" ON "ops"."bus_peers"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

REVOKE ALL ON FUNCTION "api"."health"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."health"() TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."health"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."health"() TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."health"() TO "service_role";

REVOKE ALL ON FUNCTION "bus"."ping"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."ping"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."ping"() TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."bus_ping"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."bus_ping"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."bus_ping"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."watch_bus"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."watch_bus"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."watch_bus"() TO "postgres";

GRANT SELECT ON TABLE "ops"."bus_peers" TO "authenticated";

SELECT cron.schedule_in_database('bus-watch', '*/5 * * * *', 'select ops.watch_bus()', 'postgres', NULL, true);
