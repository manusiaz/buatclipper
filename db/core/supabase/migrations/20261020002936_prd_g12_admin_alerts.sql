SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION ops.raise_alert (
  p_kind     text,
  p_severity text,
  p_payload  jsonb,
  p_dedupe   interval DEFAULT NULL::interval
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  aid bigint;
begin
  if p_dedupe is not null and exists (select 1 from ops.alerts a where a.kind = p_kind and a.resolved_at is null
                                        and a.created_at > now() - p_dedupe) then
    return null;
  end if;
  insert into ops.alerts (kind, severity, payload) values (p_kind, p_severity, coalesce(p_payload, '{}')) returning id into aid;
  -- F-X01 admin (alur 4): job tracking gagal, lonjakan fraud, payout gagal, selisih rekonsiliasi → email admin terkait lewat
  -- bridge identity (tanpa PII; payload tidak dikirim). Maks satu email per jenis per jam supaya alert beruntun tidak spam.
  if p_kind in ('tracking.lag', 'tracking.final_missing', 'fraud.flag_spike', 'payout.failed', 'payout.instant_stuck',
                'reconcile.ledger', 'reconcile.orphans')
     and not exists (select 1 from ops.alerts a where a.kind = p_kind and a.id <> aid and a.created_at > now() - interval '1 hour') then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', p_kind, 'severity', p_severity,
                                                             'alert_id', aid));
  end if;
  return aid;
end $function$;
