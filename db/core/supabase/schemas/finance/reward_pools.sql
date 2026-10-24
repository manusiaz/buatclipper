-- E-09 pool per campaign per reward type. allocated = cache saldo akun campaign_pool (E-14), hanya ditulis accrue_earnings &
-- reverse_earning dalam transaksi yang sama dengan jurnal E-15. Sisa budget terlihat siapa pun yang bisa melihat campaign-nya
-- (card F-C03: "± x views lagi"; dashboard brand F-B05).
create table finance.reward_pools (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  reward_type_id uuid not null references market.reward_types (id),
  total numeric(30, 10) not null check (total > 0),
  allocated numeric(30, 10) not null default 0,
  max_per_clip numeric(30, 10) not null check (max_per_clip > 0),
  constraint reward_pools_allocated_range check (allocated >= 0 and allocated <= total),
  constraint reward_pools_key unique (id, campaign_id, reward_type_id)
);
create index reward_pools_campaign_idx on finance.reward_pools (campaign_id);
create index reward_pools_reward_type_idx on finance.reward_pools (reward_type_id);

alter table finance.reward_pools enable row level security;
create policy reward_pools_iss on finance.reward_pools as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy reward_pools_visible on finance.reward_pools for select to anon, authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from market.campaigns c where c.id = campaign_id));
grant select on finance.reward_pools to anon, authenticated;
