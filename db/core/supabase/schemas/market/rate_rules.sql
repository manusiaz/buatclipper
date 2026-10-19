-- E-08 rate rule (§10.2). Pool wajib milik campaign & reward type yang sama (FK komposit ke E-09).
-- Parameter divalidasi per kind di constraint, bukan hanya di builder.
create table market.rate_rules (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  kind text not null check (kind in ('per_1k_views', 'flat_per_post', 'milestone_bonus', 'tiered_cpm')),
  reward_type_id uuid not null references market.reward_types (id),
  pool_id uuid not null,
  platform market.platform,
  params jsonb not null check (jsonb_typeof(params) = 'object'),
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  constraint rate_rules_effective_range check (effective_to is null or effective_to > effective_from),
  constraint rate_rules_pool_match foreign key (pool_id, campaign_id, reward_type_id)
    references finance.reward_pools (id, campaign_id, reward_type_id),
  constraint rate_rules_params_per_kind check (
       (kind = 'per_1k_views' and params ? 'rate')
    or (kind = 'flat_per_post' and params ? 'amount')
    or (kind = 'milestone_bonus' and params ? 'threshold' and params ? 'amount')
    or (kind = 'tiered_cpm' and jsonb_typeof(params -> 'tiers') = 'array'))
);
create index rate_rules_campaign_idx on market.rate_rules (campaign_id);
create index rate_rules_reward_type_idx on market.rate_rules (reward_type_id);
create index rate_rules_pool_idx on market.rate_rules (pool_id, campaign_id, reward_type_id);

alter table market.rate_rules enable row level security;
create policy rate_rules_iss on market.rate_rules as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy rate_rules_visible on market.rate_rules for select to anon, authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from market.campaigns c where c.id = campaign_id));
grant select on market.rate_rules to anon, authenticated;
