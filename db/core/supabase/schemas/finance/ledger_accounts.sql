-- E-14 akun ledger. owner_id: user (user_wallet), pool (campaign_pool), org (org_credit = rollover sisa budget, D-09);
-- akun platform tanpa owner. Satu akun per (owner, reward type).
create table finance.ledger_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_type text not null check (owner_type in ('user_wallet', 'campaign_pool', 'org_credit', 'platform_revenue',
                                                 'bank_clearing', 'tax_payable')),
  owner_id uuid,
  reward_type_id uuid not null references market.reward_types (id),
  created_at timestamptz not null default now(),
  constraint ledger_accounts_owner check ((owner_type in ('platform_revenue', 'bank_clearing', 'tax_payable')) = (owner_id is null)),
  constraint ledger_accounts_one_per_owner unique nulls not distinct (owner_type, owner_id, reward_type_id),
  constraint ledger_accounts_key unique (id, reward_type_id)
);
create index ledger_accounts_reward_type_idx on finance.ledger_accounts (reward_type_id);
create index ledger_accounts_owner_idx on finance.ledger_accounts (owner_id, owner_type);

alter table finance.ledger_accounts enable row level security;
create policy ledger_accounts_iss on finance.ledger_accounts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy ledger_accounts_own_wallet on finance.ledger_accounts for select to authenticated  -- policy:core.rls-self
  using (owner_type = 'user_wallet' and owner_id = (select auth.uid()));
create policy ledger_accounts_org_credit on finance.ledger_accounts for select to authenticated  -- policy:core.org-role
  using (owner_type = 'org_credit' and (select ops.is_org_member(owner_id, 'brand_owner', 'brand_finance')));
create policy ledger_accounts_admin_read on finance.ledger_accounts for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_finance')));
grant select on finance.ledger_accounts to authenticated;
