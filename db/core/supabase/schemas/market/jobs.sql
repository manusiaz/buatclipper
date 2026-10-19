-- Utilisasi budget (F-B08) + job:budget-alerts. Proyeksi dipakai juga dashboard brand (api.campaign_stats).

-- Proyeksi pemakaian budget: rata-rata spend Rupiah per hari sejak start_at, diproyeksikan sampai akhir view window
-- (submit_deadline + view_window_days, batas akhir earning). Angka Rupiah = Σ unit × idr_value_per_unit per pool.
create function market.campaign_projection(p_campaign uuid) returns jsonb
language sql stable set search_path = '' as $$
  with b as (
    select coalesce(sum(pl.total * rt.idr_value_per_unit), 0) as budget, coalesce(sum(pl.allocated * rt.idr_value_per_unit), 0) as spent
      from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
     where pl.campaign_id = p_campaign
  ), t as (
    select c.status, c.submit_deadline, b.budget, b.spent,
           greatest(extract(epoch from now() - coalesce(c.start_at, c.created_at)) / 86400, 0) as elapsed,
           c.submit_deadline + make_interval(days => c.view_window_days) as horizon
      from market.campaigns c cross join b
     where c.id = p_campaign
  ), x as (
    select t.*, t.spent / greatest(t.elapsed, 1) as daily,
           coalesce(greatest(extract(epoch from t.horizon - now()) / 86400, 0), 0) as days_left
      from t
  )
  select jsonb_build_object(
    'budget_idr', trim_scale(round(x.budget, 2)),
    'spent_idr', trim_scale(round(x.spent, 2)),
    'remaining_idr', trim_scale(round(x.budget - x.spent, 2)),
    'utilization_pct', case when x.budget > 0 then trim_scale(round(x.spent / x.budget * 100, 2)) end,
    'elapsed_days', trim_scale(round(x.elapsed, 2)),
    'daily_spend_idr', trim_scale(round(x.daily, 2)),
    'submit_deadline', x.submit_deadline,
    'horizon_at', x.horizon,
    'projected_utilization_pct', case when x.budget > 0
                                      then trim_scale(round(least(x.budget, x.spent + x.daily * x.days_left) / x.budget * 100, 2)) end,
    'projected_exhaust_at', case when x.daily > 0 and x.budget > x.spent
                                 then now() + make_interval(days => ceil(least((x.budget - x.spent) / x.daily, 3650))::int) end,
    'exhausts_before_horizon', case when x.horizon is not null and x.budget > 0
                                    then x.spent + x.daily * x.days_left >= x.budget end)
  from x;
$$;

-- Alert yang sudah terkirim per campaign (sekali per ambang). Ditulis job budget-alerts; dibaca anggota org lewat RLS.
create table market.budget_alerts (
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  kind text not null check (kind in ('used_50', 'used_80', 'used_100', 'projection_low')),
  utilization_pct numeric(7, 2),
  created_at timestamptz not null default now(),
  primary key (campaign_id, kind)
);

alter table market.budget_alerts enable row level security;
create policy budget_alerts_iss on market.budget_alerts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy budget_alerts_org_read on market.budget_alerts for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
create policy budget_alerts_admin_read on market.budget_alerts for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.budget_alerts to authenticated;
create view api.budget_alerts with (security_invoker = true) as
  select campaign_id, kind, utilization_pct, created_at from market.budget_alerts;
grant select on api.budget_alerts to authenticated;

-- job:budget-alerts (30 menit): budget terpakai 50/80/100% → budget.used (sekali per ambang; kalau beberapa ambang terlewati
-- sekaligus, hanya yang tertinggi yang dikirim), proyeksi < 50% saat live (setelah ≥ 2 hari berjalan) → budget.projection_low.
-- Penerima: brand_owner + brand_manager (+ agency tertaut). Mengembalikan jumlah notifikasi.
create function market.run_budget_alerts() returns int
language plpgsql security definer set search_path = '' as $$
declare
  c record;
  pj jsonb;
  util numeric;
  th int;
  top int;
  n int := 0;
  roles constant market.org_role[] := array['brand_owner', 'brand_manager']::market.org_role[];
begin
  for c in select x.id, x.org_id, x.title, x.status from market.campaigns x
            where x.status in ('live', 'paused', 'tracking', 'exhausted') loop
    pj := market.campaign_projection(c.id);
    util := (pj ->> 'utilization_pct')::numeric;
    if util is null then
      continue;
    end if;
    top := null;
    foreach th in array array[50, 80, 100] loop
      if util >= th then
        insert into market.budget_alerts (campaign_id, kind, utilization_pct) values (c.id, 'used_' || th, util)
        on conflict do nothing;
        if found then
          top := th;
        end if;
      end if;
    end loop;
    if top is not null then
      n := n + market.notify_org(c.org_id, roles, 'budget.used',
                                 jsonb_build_object('campaign_id', c.id, 'title', c.title, 'pct', top, 'utilization_pct', util));
    end if;
    if c.status = 'live' and (pj ->> 'elapsed_days')::numeric >= 2 and (pj ->> 'projected_utilization_pct')::numeric < 50 then
      insert into market.budget_alerts (campaign_id, kind, utilization_pct) values (c.id, 'projection_low', util)
      on conflict do nothing;
      if found then
        n := n + market.notify_org(c.org_id, roles, 'budget.projection_low',
                                   jsonb_build_object('campaign_id', c.id, 'title', c.title,
                                                      'projected_utilization_pct', pj -> 'projected_utilization_pct',
                                                      'suggestions', jsonb_build_array('raise_rate', 'extend', 'invite', 'pin')));
      end if;
    end if;
  end loop;
  return n;
end $$;

revoke execute on function market.campaign_projection(uuid), market.run_budget_alerts() from public;
