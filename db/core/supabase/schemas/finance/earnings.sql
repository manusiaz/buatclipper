-- Mesin earning §10.5 (deterministik & idempoten). Jurnal: campaign_pool → user_wallet(pending) per (snapshot, rule),
-- ref_id = '<snapshot_id>:<rule_id>'. finance.clip_earnings = cache per (submisi, rule) yang ditulis di transaksi yang sama
-- dengan jurnal (seperti reward_pools.allocated): dipakai cap per klip, bonus sekali bayar, koreksi turun, reversal, release.
--   amount  = earning bersih yang sudah dijurnal dari rule ini (pending; tetap tercatat setelah release)
--   demand  = jatah settlement mode yang belum dijurnal (lihat finance.settle_pool)
--   views_from/views_to = rentang views kumulatif yang dibayar rule view-based (dasar koreksi turun saat lock)
create table finance.clip_earnings (
  submission_id uuid not null references tracking.submissions (id),
  rule_id uuid not null references market.rate_rules (id),
  pool_id uuid not null references finance.reward_pools (id),
  amount numeric(30, 10) not null default 0 check (amount >= 0),
  demand numeric(30, 10) not null default 0 check (demand >= 0),
  demand_snapshot bigint references tracking.view_snapshots (id),
  views_from bigint check (views_from >= 0),
  views_to bigint,
  once_paid boolean not null default false,
  released_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (submission_id, rule_id),
  constraint clip_earnings_views_range check (views_to is null or views_from is null or views_to >= views_from),
  constraint clip_earnings_demand_has_snapshot check (demand = 0 or demand_snapshot is not null)
);
create index clip_earnings_rule_idx on finance.clip_earnings (rule_id);
create index clip_earnings_pool_idx on finance.clip_earnings (pool_id);
create index clip_earnings_demand_snapshot_idx on finance.clip_earnings (demand_snapshot);

alter table finance.clip_earnings enable row level security;
create policy clip_earnings_iss on finance.clip_earnings as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy clip_earnings_visible on finance.clip_earnings for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from tracking.submissions s where s.id = submission_id));
grant select on finance.clip_earnings to authenticated;

create view api.clip_earnings with (security_invoker = true) as
  select submission_id, rule_id, pool_id, amount, demand, released_at, updated_at from finance.clip_earnings;
grant select on api.clip_earnings to authenticated;

-- Settlement mode (§10.5 langkah 5) per pool: ada baris = pool sedang settlement sejak cutoff_at.
create table finance.pool_settlements (
  pool_id uuid primary key references finance.reward_pools (id) on delete cascade,
  cutoff_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table finance.pool_settlements enable row level security;
create policy pool_settlements_iss on finance.pool_settlements as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy pool_settlements_visible on finance.pool_settlements for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from finance.reward_pools p where p.id = pool_id));
grant select on finance.pool_settlements to authenticated;

-- Earning rule view-based untuk rentang views kumulatif (p_from, p_to]. numeric penuh, tanpa pembulatan.
create function finance.rule_amount(p_kind text, p_params jsonb, p_from bigint, p_to bigint) returns numeric
language plpgsql immutable set search_path = '' as $$
declare
  t jsonb;
  lo numeric;
  hi numeric;
  total numeric := 0;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    return 0;
  end if;
  if p_kind = 'per_1k_views' then
    return (p_to - p_from) * (p_params ->> 'rate')::numeric / 1000;
  elsif p_kind = 'tiered_cpm' then
    for t in select x.value from jsonb_array_elements(p_params -> 'tiers') x loop
      lo := greatest(p_from, coalesce((t ->> 'from')::numeric, 0));
      hi := least(p_to, coalesce((t ->> 'to')::numeric, p_to));
      if hi > lo then
        total := total + (hi - lo) * (t ->> 'rate')::numeric / 1000;
      end if;
    end loop;
    return total;
  end if;
  return 0;
end $$;

-- Masuk settlement mode: catat cut-off dan minta semua submisi tracking campaign itu segera di-poll (skip locked: baris yang
-- sedang dipegang worker lain memang sedang di-poll; menunggu kuncinya bisa deadlock dengan alokasi pool).
create function finance.start_settlement(p_pool uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into finance.pool_settlements (pool_id, cutoff_at) values (p_pool, now()) on conflict (pool_id) do nothing;
  if found then
    update tracking.submissions t set next_poll_at = now()
     where t.id in (select o.id from tracking.submissions o join finance.reward_pools rp on rp.campaign_id = o.campaign_id
                    where rp.id = p_pool and o.status = 'tracking' and o.next_poll_at > now()
                    for update of o skip locked);
  end if;
end $$;

-- Semua pool habis (dan tidak ada settlement berjalan) → campaign exhausted (S-01).
create function finance.check_exhausted(p_campaign uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from finance.reward_pools rp where rp.campaign_id = p_campaign)
     and not exists (select 1 from finance.reward_pools rp where rp.campaign_id = p_campaign and rp.allocated < rp.total)
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = p_campaign) then
    update market.campaigns set status = 'exhausted' where id = p_campaign and status in ('live', 'paused', 'tracking');
  end if;
end $$;

-- fn:accrue_earnings (kontrak internal.accrue_earnings). Satu snapshot:
--   Δ = views − counted_views, hanya submisi tracking, snapshot dalam view window (atau snapshot final), min_views: sebelum tembus
--   counted_views tetap 0 sehingga accrual pertama setelah tembus membayar semua views. Per rule aktif pada taken_at snapshot
--   (raise_rate = rule lama ditutup effective_to, rule baru mulai), filter platform. flat_per_post sekali di accrual pertama
--   (tidak tergantung min_views: dibayar per posting approved); milestone_bonus sekali saat threshold dilewati.
--   Cap per klip = pool.max_per_clip atas jumlah rule satu pool; alokasi pool atomik (pool dikunci urut id); kurang → sisa
--   dialokasikan, rule berhenti. Snapshot final dengan views turun → koreksi turun (finance.correct_down).
create function finance.accrue_earnings(p_submission uuid, p_snapshot bigint) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Koreksi turun di snapshot final (§10.5 langkah 6, FR-08): target per rule = earning rentang views yang masih ada
-- (views_from, min(views_to, views_final)], dibatasi yang sudah dibayar; milestone batal kalau di bawah threshold; flat tetap.
-- Selisih diambil dari demand settlement dulu, sisanya dijurnal pending → pool (ref_type reversal, ref_id snapshot:rule).
create function finance.correct_down(p_submission uuid, p_snapshot bigint, p_views bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  x record;
  sub record;
  total numeric;
  target numeric;
  diff numeric;
  from_demand numeric;
  from_amount numeric;
  entries jsonb := '[]';
begin
  select t.user_id, t.campaign_id, k.min_views into sub
    from tracking.submissions t join market.campaigns k on k.id = t.campaign_id where t.id = p_submission;
  perform 1 from finance.reward_pools fp where fp.campaign_id = sub.campaign_id order by fp.id for update;
  for x in select ce.*, rr.kind, rr.params, rp.reward_type_id from finance.clip_earnings ce
             join market.rate_rules rr on rr.id = ce.rule_id join finance.reward_pools rp on rp.id = ce.pool_id
            where ce.submission_id = p_submission and ce.released_at is null and ce.amount + ce.demand > 0
            order by ce.pool_id, ce.rule_id loop
    total := x.amount + x.demand;
    target := case
      when x.kind = 'flat_per_post' then total
      when x.kind = 'milestone_bonus' then
        case when p_views >= greatest(sub.min_views, (x.params ->> 'threshold')::numeric) then total else 0 end
      when p_views < sub.min_views then 0
      else least(total, trunc(finance.rule_amount(x.kind, x.params, x.views_from, least(x.views_to, p_views)), 10)) end;
    diff := total - target;
    continue when diff <= 0;
    from_demand := least(x.demand, diff);
    from_amount := diff - from_demand;
    update finance.clip_earnings ce set demand = ce.demand - from_demand, amount = ce.amount - from_amount,
           -- views turun di bawah awal rule (rule baru berlaku sejak views_from): earning rule itu hangus seluruhnya
           views_to = greatest(ce.views_from, least(ce.views_to, p_views)), updated_at = now()
     where ce.submission_id = x.submission_id and ce.rule_id = x.rule_id;
    if from_amount > 0 then
      entries := entries || jsonb_build_array(
        finance.e(finance.account('user_wallet', sub.user_id, x.reward_type_id), -from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id, 'pending'),
        finance.e(finance.account('campaign_pool', x.pool_id, x.reward_type_id), from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id));
      update finance.reward_pools set allocated = allocated - from_amount where id = x.pool_id;
    end if;
  end loop;
  perform finance.post(gen_random_uuid(), entries);
end $$;

-- fn:reverse_earning — semua earning pending submisi (yang belum dirilis) kembali ke pool; demand settlement dibatalkan.
-- Idempoten lewat state: panggilan kedua tidak menemukan apa pun. Yang sudah Tersedia tidak disentuh.
create function finance.reverse_earning(p_submission uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s tracking.submissions;
  x record;
  txn uuid := gen_random_uuid();
  entries jsonb := '[]';
  reversed jsonb := '{}';
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
  for x in select ce.rule_id, ce.pool_id, ce.amount, rp.reward_type_id from finance.clip_earnings ce
             join finance.reward_pools rp on rp.id = ce.pool_id
            where ce.submission_id = s.id and ce.released_at is null and (ce.amount > 0 or ce.demand > 0)
            order by ce.pool_id, ce.rule_id loop
    if x.amount > 0 then
      entries := entries || jsonb_build_array(
        finance.e(finance.account('user_wallet', s.user_id, x.reward_type_id), -x.amount, 'reversal',
                  s.id || ':' || x.rule_id || ':' || txn, 'pending'),
        finance.e(finance.account('campaign_pool', x.pool_id, x.reward_type_id), x.amount, 'reversal',
                  s.id || ':' || x.rule_id || ':' || txn));
      update finance.reward_pools set allocated = allocated - x.amount where id = x.pool_id;
      reversed := reversed || jsonb_build_object(x.reward_type_id::text,
                                                 coalesce((reversed ->> x.reward_type_id::text)::numeric, 0) + x.amount);
    end if;
    update finance.clip_earnings ce set amount = 0, demand = 0, updated_at = now()
     where ce.submission_id = s.id and ce.rule_id = x.rule_id;
  end loop;
  perform finance.post(txn, entries);
  if reversed <> '{}' then
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values ((select auth.uid()), 'earning.reverse', 'submission:' || s.id, null,
            jsonb_build_object('reason', p_reason, 'txn_id', txn, 'amounts', reversed));
  end if;
end $$;

-- Akhiri settlement satu pool: sisa pool dibagi pro-rata ke demand (tiap submisi dihitung dari snapshot pertamanya setelah
-- cut-off, jadi urutan poll tidak menentukan jatah). Demand ≤ sisa → dibayar penuh dan mode selesai (accrual berikutnya
-- masuk settlement lagi kalau sisa masih < ambang). Demand > sisa → bagian = trunc(demand × sisa ÷ total demand, 10);
-- recehan 1e-10 dibagikan ke selisih terbesar, jadi jumlahnya tepat = sisa dan pool habis.
create function finance.settle_pool(p_pool uuid) returns void
language plpgsql security definer set search_path = '' as $$
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
  rem := p.total - p.allocated;
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
end $$;

-- Dipanggil job lifecycle: settlement siap diakhiri kalau semua submisi tracking campaign sudah di-poll sejak cut-off
-- (yang polling-nya di-pause tidak ditunggu) atau batas tunggu finance.settlement_wait_hours lewat.
create function finance.finalize_settlements() returns void
language plpgsql security definer set search_path = '' as $$
declare
  wait interval := (ops.cfg('finance.settlement_wait_hours', '6'))::numeric * interval '1 hour';
  st record;
begin
  for st in select ps.pool_id from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
             where ps.cutoff_at <= now() - wait
                or not exists (select 1 from tracking.submissions t
                               where t.campaign_id = rp.campaign_id and t.status = 'tracking' and t.next_poll_at is not null
                                 and coalesce(t.last_snapshot_at, '-infinity') < ps.cutoff_at)
             order by ps.pool_id loop
    perform finance.settle_pool(st.pool_id);
  end loop;
end $$;

-- fn:release_earnings (job earning-release): submisi locked + hold (public.finance.hold_days) tanpa fraud flag terbuka di submisi,
-- profil, atau akun sosmednya, dan tanpa demand settlement tertunda → pending ke Tersedia, submisi settled. Pembulatan ke bawah
-- (decimals reward type) hanya di sini; recehan kembali ke pool. ref_id = '<submission_id>:<pool_id>'.
create function finance.release_earnings() returns void
language plpgsql security definer set search_path = '' as $$
declare
  hold int := (ops.cfg('public.finance.hold_days', '7'))::int;
  s record;
  g record;
  wallet uuid;
  avail numeric;
  entries jsonb;
  released jsonb;
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
    perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
    for g in select ce.pool_id, rp.reward_type_id, rt.code, rt.decimals, sum(ce.amount) as amount
               from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
               join market.reward_types rt on rt.id = rp.reward_type_id
              where ce.submission_id = s.id and ce.released_at is null
              group by ce.pool_id, rp.reward_type_id, rt.code, rt.decimals having sum(ce.amount) > 0
              order by ce.pool_id loop
      wallet := finance.account('user_wallet', s.user_id, g.reward_type_id);
      avail := trunc(g.amount, g.decimals);
      entries := entries || jsonb_build_array(
        finance.e(wallet, -g.amount, 'release', s.id || ':' || g.pool_id, 'pending'),
        finance.e(wallet, avail, 'release', s.id || ':' || g.pool_id, 'available'),
        finance.e(finance.account('campaign_pool', g.pool_id, g.reward_type_id), g.amount - avail, 'release', s.id || ':' || g.pool_id));
      if g.amount > avail then
        update finance.reward_pools set allocated = allocated - (g.amount - avail) where id = g.pool_id;
      end if;
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
end $$;

revoke execute on function finance.rule_amount(text, jsonb, bigint, bigint), finance.start_settlement(uuid),
  finance.check_exhausted(uuid), finance.accrue_earnings(uuid, bigint), finance.correct_down(uuid, bigint, bigint),
  finance.reverse_earning(uuid, text), finance.settle_pool(uuid), finance.finalize_settlements(), finance.release_earnings()
  from public;
