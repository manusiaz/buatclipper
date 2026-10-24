SET local check_function_bodies = off;

ALTER TABLE "ops"."alerts"
  ADD COLUMN "notified_at" timestamp WITH time zone;

CREATE OR REPLACE FUNCTION api.bridge_alert_notified (
  p_alert bigint
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  update ops.alerts set notified_at = now() where id = p_alert and notified_at is null;
$function$;

CREATE OR REPLACE FUNCTION api.my_clip_terms()
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select jsonb_object_agg(p, jsonb_build_object('cap_pct', trim_scale(ct.cap_pct), 'hold_days', ct.hold_days))
    from unnest(enum_range(null::market.platform)) p,
         finance.clip_terms((select pr.trust_score from market.profiles pr where pr.id = market.session_uid()), p::text) ct;
$function$;

CREATE OR REPLACE FUNCTION finance.clip_terms (
  p_trust    integer,
  p_platform text
)
  RETURNS TABLE (
    cap_pct   numeric,
    hold_days integer
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  -- Nilai bukan angka (diedit admin di editor JSON) diabaikan, bukan menggagalkan accrual/release semua submisi.
  with t as (
    select coalesce((select x from jsonb_array_elements(case when jsonb_typeof(ops.cfg('public.finance.trust_tiers')) = 'array'
                                                             then ops.cfg('public.finance.trust_tiers') else '[]' end) x
                      where finance.jnum(x, 'min_score') <= coalesce(p_trust, 0)
                      order by finance.jnum(x, 'min_score') desc limit 1), '{}') as tier,
           coalesce(ops.cfg('public.finance.platform_rules') -> p_platform, '{}') as rule
  )
  select greatest(coalesce(finance.jnum(t.tier, 'cap_pct'), 100), 0) * greatest(coalesce(finance.jnum(t.rule, 'cap_pct'), 100), 0) / 100,
         least(greatest(coalesce(round(finance.jnum(t.tier, 'hold_days')), (ops.cfg('public.finance.hold_days', '7'))::numeric),
                        coalesce(round(finance.jnum(t.rule, 'hold_days')), 0), 0), 365)::int
    from t;
$function$;

CREATE OR REPLACE FUNCTION finance.jnum (
  p_obj jsonb,
  p_key text
)
  RETURNS numeric
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select case when jsonb_typeof(p_obj -> p_key) = 'number' then (p_obj ->> p_key)::numeric end;
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
                             'reconcile.ledger', 'reconcile.orphans')
              and (p_kind is null or a.kind = p_kind)
              and a.notified_at is null and a.resolved_at is null and a.created_at > now() - interval '1 day'
              and not exists (select 1 from ops.alerts b where b.kind = a.kind and b.notified_at > now() - interval '1 hour')
            order by a.kind, a.id desc loop
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', r.kind, 'severity', r.severity,
                                                             'alert_id', r.id));
    n := n + 1;
  end loop;
  return n;
end $function$;

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
  perform ops.notify_alerts(p_kind);
  return aid;
end $function$;

REVOKE ALL ON FUNCTION "api"."bridge_alert_notified"(bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_alert_notified"(bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_alert_notified"(bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_alert_notified"(bigint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."my_clip_terms"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."my_clip_terms"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."my_clip_terms"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."my_clip_terms"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."jnum"(jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."jnum"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."jnum"(jsonb, text) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."notify_alerts"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."notify_alerts"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."notify_alerts"(text) TO "postgres";

SELECT cron.schedule_in_database('alert-notify', '*/15 * * * *', 'select ops.notify_alerts()', 'postgres', NULL, true);
