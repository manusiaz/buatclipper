SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.appeal_submission (
  p_submission uuid,
  p_message    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  s tracking.submissions;
  pr market.profiles;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null or s.user_id <> uid then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.status is distinct from 'active' then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_message, ''))) not between 1 and 1000 then
    perform market.fail('invalid:message', 'alasan banding 1–1000 karakter');
  end if;
  if s.status <> 'rejected' then
    perform market.fail('invalid_state:' || s.status, 'banding hanya untuk submisi yang ditolak');
  end if;
  -- Campaign selesai (dana sisa bisa di-refund/rollover) → banding ditutup; banding yang berjalan menahan settle.
  if exists (select 1 from market.campaigns c where c.id = s.campaign_id and c.status in ('settling', 'settled', 'cancelled')) then
    perform market.fail('appeal_closed', 'campaign sudah selesai, banding ditutup');
  end if;
  begin
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, message)
    values ('submission', s.id, uid, 'appeal', btrim(p_message));
  exception when unique_violation then
    perform market.fail('appeal_used', 'banding hanya sekali per submisi');
  end;
  update tracking.submissions set status = 'appealed' where id = s.id;
end $function$;

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
    -- Sisa pool = total − allocated, dibatasi saldo ledger pool (dana yang sudah di-refund/rollover tidak membiayai earning).
    remaining := least(p.total - p.allocated,
                       greatest(finance.balance(finance.account('campaign_pool', p.id, p.reward_type_id)), 0));
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

CREATE OR REPLACE FUNCTION finance.settle_pool (
  p_pool uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.reward_pools;
  rem numeric;
  dsum numeric;
  paid numeric := 0;
  x record;
  entries jsonb := '[]';
  unit constant numeric := 0.0000000001;
begin
  select * into p from finance.reward_pools fp where fp.id = p_pool for update;
  rem := least(p.total - p.allocated, greatest(finance.balance(finance.account('campaign_pool', p.id, p.reward_type_id)), 0));
  select coalesce(sum(ce.demand), 0) into dsum from finance.clip_earnings ce where ce.pool_id = p.id and ce.demand > 0;
  if dsum > 0 then
    for x in with dm as (
               select ce.submission_id, ce.rule_id, ce.demand, ce.demand_snapshot, t.user_id,
                      case when dsum <= rem then ce.demand else trunc(ce.demand * rem / dsum, 10) end as share
                 from finance.clip_earnings ce join tracking.submissions t on t.id = ce.submission_id
                where ce.pool_id = p.id and ce.demand > 0),
             k as (select case when dsum <= rem then 0 else round((rem - sum(dm.share)) / unit) end as n from dm)
             select dm.*, dm.share + case when row_number() over (order by dm.demand - dm.share desc, dm.submission_id, dm.rule_id)
                                               <= k.n then unit else 0 end as pay
               from dm cross join k loop
      if x.pay > 0 then
        entries := entries || jsonb_build_array(
          finance.e(finance.account('campaign_pool', p.id, p.reward_type_id), -x.pay, 'accrual', x.demand_snapshot || ':' || x.rule_id),
          finance.e(finance.account('user_wallet', x.user_id, p.reward_type_id), x.pay, 'accrual',
                    x.demand_snapshot || ':' || x.rule_id, 'pending'));
      end if;
      update finance.clip_earnings ce set amount = ce.amount + x.pay, demand = 0, updated_at = now()
       where ce.submission_id = x.submission_id and ce.rule_id = x.rule_id;
      paid := paid + x.pay;
    end loop;
    update finance.reward_pools set allocated = allocated + paid where id = p.id;
    perform finance.post(gen_random_uuid(), entries);
  end if;
  delete from finance.pool_settlements where pool_id = p.id;
  perform finance.check_exhausted(p.campaign_id);
end $function$;
