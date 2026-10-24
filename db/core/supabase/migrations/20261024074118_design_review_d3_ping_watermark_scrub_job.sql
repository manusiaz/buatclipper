SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus.ping()
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t0 timestamptz := clock_timestamp();  -- sebelum membaca pg_stat_activity: transaksi yang mulai sesudahnya tidak diklaim
  h record;
begin
  select a.pid, a.xact_start, a.state into h from pg_stat_activity a
   where a.datname = current_database() and a.backend_type = 'client backend' and a.xact_start is not null
     and a.pid <> pg_backend_pid()
   order by a.xact_start limit 1;
  return bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(), 'at', least(t0, h.xact_start),
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')
             || case when h.xact_start < t0 - interval '5 minutes'
                     then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'since', h.xact_start, 'pid', h.pid, 'state', h.state))
                     else '[]' end));
end $function$;
