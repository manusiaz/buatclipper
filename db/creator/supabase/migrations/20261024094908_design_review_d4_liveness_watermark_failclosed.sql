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
  blind boolean;
  oldest timestamptz;
begin
  select exists (select 1 from pg_stat_activity a where a.datname = current_database() and a.backend_type = 'client backend'
                                                    and a.state is null and a.pid <> pg_backend_pid()) into blind;
  select a.pid, a.xact_start, a.state into h from pg_stat_activity a
   where a.datname = current_database() and a.backend_type = 'client backend' and a.xact_start is not null
     and a.pid <> pg_backend_pid()
   order by a.xact_start limit 1;
  oldest := least(h.xact_start, (select min(x.prepared) from pg_prepared_xacts x where x.database = current_database()));
  return bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(),
    'at', case when blind then '-infinity'::timestamptz else least(t0, oldest) end,
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')
             || case when blind then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'reason', 'pg_stat_activity tidak terbaca'))
                     when oldest < t0 - interval '5 minutes'
                     then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'since', oldest, 'pid', h.pid, 'state', h.state))
                     else '[]' end));
end $function$;
