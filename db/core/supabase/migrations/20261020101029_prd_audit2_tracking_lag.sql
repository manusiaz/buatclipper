SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.admin_overview()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
  rev uuid := (select a.id from finance.ledger_accounts a join market.reward_types rt on rt.id = a.reward_type_id
               where a.owner_type = 'platform_revenue' and rt.code = 'IDR' and rt.owner_org_id is null);
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'gmv', (select jsonb_build_object('month', coalesce(sum(i.total) filter (where i.paid_at >= month_start), 0),
                                      'all_time', coalesce(sum(i.total), 0))
              from finance.invoices i where i.status = 'paid'),
    'revenue', (select jsonb_build_object('month', coalesce(sum(e.amount) filter (where e.created_at >= month_start), 0),
                                          'all_time', coalesce(sum(e.amount), 0))
                  from finance.ledger_entries e where e.account_id = rev),
    'active_campaigns', (select count(*) from market.campaigns c where c.status in ('live', 'paused', 'tracking')),
    'payout_pending', (select jsonb_build_object('count', count(*), 'sum', coalesce(sum(p.amount), 0))
                         from finance.payouts p where p.status in ('requested', 'on_hold', 'processing')),
    'fraud_queue', (select count(*) from trust.fraud_flags f where f.status in ('open', 'held')),
    'tracking', jsonb_build_object(
      'overdue', tracking.lagging_count(),
      'last_snapshot_age_seconds', (select floor(extract(epoch from now() - max(v.taken_at))) from tracking.view_snapshots v)),
    'open_alerts', (select count(*) from ops.alerts a where a.resolved_at is null));
end $function$;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  n int;
begin
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    if fin is not null then
      perform finance.accrue_earnings(r.id, fin);
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
    elsif r.window_end + grace <= now() then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
  end loop;

  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;

CREATE OR REPLACE FUNCTION tracking.lagging_count()
  RETURNS integer
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return (select count(*)::int from (
            select s.id from tracking.submissions s
             where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours'
            union
            select (q.message ->> 'submission_id')::uuid from pgmq.q_tracking q where q.enqueued_at < now() - interval '1 hour') x);
end $function$;

REVOKE ALL ON FUNCTION "tracking"."lagging_count"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."lagging_count"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."lagging_count"() TO "postgres";
