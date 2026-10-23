SET local check_function_bodies = off;

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

CREATE INDEX inbox_source_idx ON bus.inbox USING btree (source, received_at DESC);

REVOKE ALL ON FUNCTION "api"."health"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."health"() TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."health"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."health"() TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."health"() TO "service_role";

REVOKE ALL ON FUNCTION "bus"."ping"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."ping"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."ping"() TO "postgres";

SELECT cron.schedule_in_database('bus-ping', '*/5 * * * *', 'select bus.ping()', 'postgres', NULL, true);
