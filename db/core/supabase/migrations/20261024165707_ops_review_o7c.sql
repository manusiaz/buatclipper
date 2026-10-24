SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.worker_notification (
  p_id bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n ops.notifications;
begin
  select * into n from ops.notifications x where x.id = p_id;
  if not found then
    return null;
  end if;
  -- created (detik epoch) ikut Idempotency-Key email: id saja bisa terpakai ulang sesudah restore admin dari backup (O7-C1)
  return jsonb_build_object('user_id', n.user_id, 'event', n.event, 'payload', n.payload,
                            'promo', n.event in ('campaign.new', 'broadcast.sent'),
                            'created', floor(extract(epoch from n.created_at))::bigint);
end $function$;

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
  for r in select distinct on (a.kind) a.id, a.kind, a.severity, a.created_at from ops.alerts a
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
                                                             'alert_id', r.id, 'created', floor(extract(epoch from r.created_at))::bigint));
    n := n + 1;
  end loop;
  return n;
end $function$;
