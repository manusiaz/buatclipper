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
  cap_pct numeric;
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
  select ct.cap_pct into cap_pct
    from finance.clip_terms((select pr.trust_score from market.profiles pr where pr.id = s.user_id), s.platform::text) ct;
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
      -- raise_rate menutup rule & membuat versi baru (lineage_id sama): versi yang sudah dibayar = sudah dibayar.
      when r.kind = 'flat_per_post' then
        case when coalesce(ce.once_paid, false) or exists (
                    select 1 from finance.clip_earnings x join market.rate_rules r2 on r2.id = x.rule_id
                     where x.submission_id = s.id and x.once_paid
                       and coalesce(r2.lineage_id, r2.id) = coalesce(r.lineage_id, r.id)) then 0
             else (r.params ->> 'amount')::numeric end
      when r.kind = 'milestone_bonus' then
        case when crossed and not coalesce(ce.once_paid, false) and base < (r.params ->> 'threshold')::numeric
                  and v >= (r.params ->> 'threshold')::numeric then (r.params ->> 'amount')::numeric else 0 end
      when crossed then finance.rule_amount(r.kind, r.params, base, v)
      else 0 end;
    continue when coalesce(raw, 0) <= 0;

    select * into p from finance.reward_pools fp where fp.id = r.pool_id;
    amt := trunc(least(raw, p.max_per_clip * cap_pct / 100 - coalesce((select sum(x.amount + x.demand) from finance.clip_earnings x
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
  with t as (
    select coalesce((select x from jsonb_array_elements(case when jsonb_typeof(ops.cfg('public.finance.trust_tiers')) = 'array'
                                                             then ops.cfg('public.finance.trust_tiers') else '[]' end) x
                      where (x ->> 'min_score')::int <= coalesce(p_trust, 0)
                      order by (x ->> 'min_score')::int desc limit 1), '{}') as tier,
           coalesce(ops.cfg('public.finance.platform_rules') -> p_platform, '{}') as rule
  )
  select greatest(coalesce((t.tier ->> 'cap_pct')::numeric, 100), 0) * greatest(coalesce((t.rule ->> 'cap_pct')::numeric, 100), 0) / 100,
         greatest(coalesce((t.tier ->> 'hold_days')::int, (ops.cfg('public.finance.hold_days', '7'))::int),
                  coalesce((t.rule ->> 'hold_days')::int, 0))
    from t;
$function$;

CREATE OR REPLACE FUNCTION finance.release_earnings()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  hold int := (ops.cfg('public.finance.hold_days', '7'))::int;
  s record;
  g record;
  wallet uuid;
  avail numeric;
  entries jsonb;
  released jsonb;
  idr uuid := finance.idr();
  fee_pct numeric;
  fee numeric;
begin
  for s in select t.id, t.user_id, t.campaign_id from tracking.submissions t
            where t.status = 'locked'
              and t.locked_at <= now() - make_interval(days => coalesce(
                    (select ct.hold_days from finance.clip_terms((select pr.trust_score from market.profiles pr where pr.id = t.user_id),
                                                                 t.platform::text) ct), hold))
              and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held')
                              and ((f.target_type = 'submission' and f.target_id = t.id)
                                or (f.target_type = 'profile' and f.target_id = t.user_id)
                                or (f.target_type = 'social_account' and f.target_id = t.social_account_id)))
              and not exists (select 1 from finance.clip_earnings ce where ce.submission_id = t.id and ce.demand > 0)
            order by t.locked_at limit 1000
            for update of t skip locked loop
    entries := '[]';
    released := '{}';
    -- Potongan earning clipper (E-21 clipper_fee_pct, default 0%): hanya Rupiah, dipotong saat Tertunda → Tersedia supaya
    -- reversal/koreksi (yang hanya menyentuh Tertunda) tidak perlu mengembalikan fee.
    fee_pct := coalesce((finance.effective_fee_rule((select c.org_id from market.campaigns c where c.id = s.campaign_id),
                                                    s.campaign_id)).clipper_fee_pct, 0);
    perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
    for g in select ce.pool_id, rp.reward_type_id, rt.code, rt.decimals, sum(ce.amount) as amount
               from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
               join market.reward_types rt on rt.id = rp.reward_type_id
              where ce.submission_id = s.id and ce.released_at is null
              group by ce.pool_id, rp.reward_type_id, rt.code, rt.decimals having sum(ce.amount) > 0
              order by ce.pool_id loop
      wallet := finance.account('user_wallet', s.user_id, g.reward_type_id);
      avail := trunc(g.amount, g.decimals);
      fee := case when g.reward_type_id = idr and fee_pct > 0 then trunc(avail * fee_pct / 100, g.decimals) else 0 end;
      entries := entries || jsonb_build_array(
        finance.e(wallet, -g.amount, 'release', s.id || ':' || g.pool_id, 'pending'),
        finance.e(wallet, avail - fee, 'release', s.id || ':' || g.pool_id, 'available'),
        finance.e(finance.account('campaign_pool', g.pool_id, g.reward_type_id), g.amount - avail, 'release', s.id || ':' || g.pool_id));
      if fee > 0 then
        entries := entries || jsonb_build_array(
          finance.e(finance.account('platform_revenue', null, idr), fee, 'fee', s.id || ':' || g.pool_id));
      end if;
      if g.amount > avail then
        update finance.reward_pools set allocated = allocated - (g.amount - avail) where id = g.pool_id;
      end if;
      avail := avail - fee;
      if avail > 0 then
        released := released || jsonb_build_object(g.reward_type_id::text,
                                                    coalesce((released ->> g.reward_type_id::text)::numeric, 0) + avail);
      end if;
    end loop;
    update finance.clip_earnings set released_at = now() where submission_id = s.id and released_at is null;
    update tracking.submissions set status = 'settled' where id = s.id;
    perform finance.post(gen_random_uuid(), entries);
    if released <> '{}' then
      perform ops.enqueue_notification(s.user_id, 'earning.available', market.campaign_ref(s.campaign_id) || jsonb_build_object(
        'submission_id', s.id,
        'amounts', (select jsonb_agg(finance.amount_ref(x.key::uuid, x.value::numeric)) from jsonb_each_text(released) x)));
    end if;
  end loop;
end $function$;

REVOKE ALL ON FUNCTION "finance"."clip_terms"(integer, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."clip_terms"(integer, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."clip_terms"(integer, text) TO "postgres";
