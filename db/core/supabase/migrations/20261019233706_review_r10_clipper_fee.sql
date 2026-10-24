SET local check_function_bodies = off;

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
            where t.status = 'locked' and t.locked_at <= now() - make_interval(days => hold)
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
