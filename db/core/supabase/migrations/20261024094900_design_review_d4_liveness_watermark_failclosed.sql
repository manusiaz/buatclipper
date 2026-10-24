SET local check_function_bodies = off;

ALTER TABLE "ops"."bus_peers"
  ADD COLUMN "seen_at" timestamp WITH time zone NOT NULL DEFAULT now();

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

CREATE OR REPLACE FUNCTION bus_in.bus_ping (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into ops.bus_peers (source, pinged_at, seen_at, stuck)
  select p ->> '_source', coalesce((p ->> 'at')::timestamptz, now()), now(),
         case when jsonb_typeof(p -> 'stuck') = 'array' then p -> 'stuck' else '[]' end
   where p ->> '_source' in ('creator', 'brand')
  on conflict (source) do update set pinged_at = greatest(ops.bus_peers.pinged_at, excluded.pinged_at), seen_at = now(),
                                     stuck = excluded.stuck;
$function$;

CREATE OR REPLACE FUNCTION ops.notify_alerts (
  p_kind text DEFAULT NULL::text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
begin
  for r in select distinct on (a.kind) a.id, a.kind, a.severity from ops.alerts a
            where a.kind in ('tracking.lag', 'tracking.final_missing', 'fraud.flag_spike', 'payout.failed', 'payout.instant_stuck',
                             'reconcile.ledger', 'reconcile.orphans', 'reconcile.bank',
                             -- antar-DB: antrean macet, hook replika gagal, payload ditolak, isi campaign yang disetujui berubah
                             'bus.stuck', 'bus.watermark_held', 'bus.rejected_payload', 'tracking.apply_failed', 'campaign.apply_failed',
                             'campaign.content_drift')
              and (p_kind is null or a.kind = p_kind)
              and a.notified_at is null and a.resolved_at is null and a.created_at > now() - interval '1 day'
              and not exists (select 1 from ops.alerts b
                               where b.kind = a.kind and (b.notified_at > now() - interval '1 hour'
                                                          or b.notify_requested_at > now() - interval '15 minutes'))
            order by a.kind, a.id desc loop
    continue when not pg_try_advisory_xact_lock(hashtext('ops.notify_alerts:' || r.kind));
    -- Setelah lock: transaksi lain yang baru commit mungkin sudah meminta kirim (snapshot statement baru).
    continue when exists (select 1 from ops.alerts b
                           where b.kind = r.kind and b.id <> r.id
                             and (b.notified_at > now() - interval '1 hour' or b.notify_requested_at > now() - interval '15 minutes'));
    update ops.alerts set notify_requested_at = now() where id = r.id;
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', r.kind, 'severity', r.severity,
                                                             'alert_id', r.id));
    n := n + 1;
  end loop;
  return n;
end $function$;

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
  held jsonb;
begin
  select jsonb_agg(p.source order by p.source) into late from ops.bus_peers p where p.seen_at < now() - interval '15 minutes';
  select jsonb_agg(jsonb_build_object('source', p.source) || e.value) into peer_stuck
    from ops.bus_peers p cross join lateral jsonb_array_elements(p.stuck) e where e.value ->> 'target' <> 'transaksi';
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('source', p.source, 'watermark', p.pinged_at,
           'transaksi', (select jsonb_agg(e.value) from jsonb_array_elements(p.stuck) e where e.value ->> 'target' = 'transaksi')))
           order by p.source) into held
    from ops.bus_peers p where p.pinged_at < now() - interval '1 hour' and p.seen_at >= now() - interval '15 minutes';
  if held is not null then
    perform ops.raise_alert('bus.watermark_held', 'warning', jsonb_build_object('held', held), interval '1 hour');
  end if;
  select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts)) into own_stuck from bus.stuck() s;
  if late is not null or peer_stuck is not null or own_stuck is not null then
    perform ops.raise_alert('bus.stuck', 'critical', jsonb_strip_nulls(jsonb_build_object('late', late, 'peer_stuck', peer_stuck,
                                                                                         'admin_stuck', own_stuck)), interval '1 hour');
  end if;
end $function$;
