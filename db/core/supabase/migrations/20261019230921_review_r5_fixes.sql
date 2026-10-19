SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION finance.accrue_earnings (
  p_submission uuid,
  p_snapshot   bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  snap tracking.view_snapshots;
  c market.campaigns;
  r market.rate_rules;
  p finance.reward_pools;
  ce finance.clip_earnings;
  pct numeric := (ops.cfg('finance.settlement_threshold_pct', '5'))::numeric;
  entries jsonb := '[]';
  v bigint;
  base bigint;
  crossed boolean;
  view_based boolean;
  raw numeric;
  amt numeric;
  remaining numeric;
  in_settle boolean;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  select * into snap from tracking.view_snapshots vs where vs.id = p_snapshot and vs.submission_id = p_submission;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  if s.status <> 'tracking' then
    return;  -- flagged/belum approved: Δ menunggu; dihitung dari counted_views saat kembali tracking
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  v := snap.views;
  base := s.counted_views;
  if snap.is_final and v < base then
    perform finance.correct_down(s.id, snap.id, v);
    update tracking.submissions set counted_views = v where id = s.id;
    return;
  end if;
  if not snap.is_final and snap.taken_at > s.posted_at + make_interval(days => c.view_window_days) then
    return;
  end if;
  crossed := v >= c.min_views;

  perform 1 from finance.reward_pools fp where fp.campaign_id = c.id order by fp.id for update;
  for r in select rr.* from market.rate_rules rr
            where rr.campaign_id = c.id and rr.effective_from <= snap.taken_at
              and (rr.effective_to is null or rr.effective_to > snap.taken_at)
              and (rr.platform is null or rr.platform = s.platform)
            order by rr.pool_id, rr.effective_from, rr.id loop
    select * into ce from finance.clip_earnings x where x.submission_id = s.id and x.rule_id = r.id;
    view_based := r.kind in ('per_1k_views', 'tiered_cpm');
    raw := case
      -- raise_rate menutup rule & membuat rule baru: versi lama (pool, kind, platform sama) yang sudah dibayar = sudah dibayar.
      when r.kind = 'flat_per_post' then
        case when coalesce(ce.once_paid, false) or exists (
                    select 1 from finance.clip_earnings x join market.rate_rules r2 on r2.id = x.rule_id
                     where x.submission_id = s.id and x.once_paid and r2.pool_id = r.pool_id and r2.kind = r.kind
                       and r2.platform is not distinct from r.platform) then 0
             else (r.params ->> 'amount')::numeric end
      when r.kind = 'milestone_bonus' then
        case when crossed and not coalesce(ce.once_paid, false) and base < (r.params ->> 'threshold')::numeric
                  and v >= (r.params ->> 'threshold')::numeric then (r.params ->> 'amount')::numeric else 0 end
      when crossed then finance.rule_amount(r.kind, r.params, base, v)
      else 0 end;
    continue when coalesce(raw, 0) <= 0;

    select * into p from finance.reward_pools fp where fp.id = r.pool_id;
    amt := trunc(least(raw, p.max_per_clip - coalesce((select sum(x.amount + x.demand) from finance.clip_earnings x
                                                        where x.submission_id = s.id and x.pool_id = p.id), 0)), 10);
    continue when amt <= 0;
    remaining := p.total - p.allocated;
    in_settle := exists (select 1 from finance.pool_settlements ps where ps.pool_id = p.id);
    if not in_settle and remaining > 0 and remaining * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
      in_settle := true;
    end if;

    if in_settle then
      insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, demand, demand_snapshot, views_from, views_to, once_paid)
      values (s.id, r.id, p.id, amt, snap.id, case when view_based then base end, case when view_based then v end, not view_based)
      on conflict (submission_id, rule_id) do update
        set demand = x.demand + excluded.demand, demand_snapshot = excluded.demand_snapshot,
            views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
            once_paid = x.once_paid or excluded.once_paid, updated_at = now();
      continue;
    end if;

    amt := least(amt, remaining);
    continue when amt <= 0;
    entries := entries || jsonb_build_array(
      finance.e(finance.account('campaign_pool', p.id, p.reward_type_id), -amt, 'accrual', snap.id || ':' || r.id),
      finance.e(finance.account('user_wallet', s.user_id, p.reward_type_id), amt, 'accrual', snap.id || ':' || r.id, 'pending'));
    update finance.reward_pools set allocated = allocated + amt where id = p.id;
    insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, amount, views_from, views_to, once_paid)
    values (s.id, r.id, p.id, amt, case when view_based then base end, case when view_based then v end, not view_based)
    on conflict (submission_id, rule_id) do update
      set amount = x.amount + excluded.amount,
          views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
          once_paid = x.once_paid or excluded.once_paid, updated_at = now();
    if remaining - amt > 0 and (remaining - amt) * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
    end if;
  end loop;

  if crossed and v > base then
    update tracking.submissions set counted_views = v where id = s.id;
  end if;
  perform finance.post(gen_random_uuid(), entries);
  perform finance.check_exhausted(c.id);
end $function$;

CREATE VIEW "api"."fulfillment_exports" WITH (security_invoker=true) AS  SELECT reward_type_id,
    export_ref AS file_ref,
    (count(*))::integer AS rows,
    (count(*) FILTER (WHERE (status = 'processing'::finance.fulfillment_status)))::integer AS pending
   FROM finance.fulfillments f
  WHERE ((export_ref IS NOT NULL) AND ( SELECT ops.has_admin() AS has_admin))
  GROUP BY reward_type_id, export_ref;

GRANT SELECT ON TABLE "api"."fulfillment_exports" TO "authenticated";
