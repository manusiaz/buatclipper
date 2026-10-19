-- E-17 payout Rupiah. Status mengikuti S-05. method_id = rujukan rekening E-16 di identity (tanpa FK; pemilik dicek ulang
-- pii-export, alur 3). proof_ref = bukti transfer di bucket payout-proofs (identity). Satu idempotency_key = satu payout.
create table finance.payouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references market.profiles (id),
  method_id uuid not null,
  batch_id uuid references finance.payout_batches (id),
  amount numeric(18, 2) not null check (amount > 0),
  fee numeric(18, 2) not null default 0 check (fee >= 0),
  channel text not null default 'batch' check (channel in ('batch', 'instant')),
  status finance.payout_status not null default 'requested',
  hold_reason text,
  bank_ref text,
  proof_ref text,
  provider_ref text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  constraint payouts_idempotency_unique unique (idempotency_key),
  constraint payouts_provider_ref_unique unique (provider_ref),
  constraint payouts_instant_no_batch check (channel = 'batch' or batch_id is null),
  constraint payouts_fee_below_amount check (fee < amount),
  constraint payouts_hold_has_reason check (status <> 'on_hold' or hold_reason is not null),
  constraint payouts_paid_complete check (status <> 'paid' or (paid_at is not null and ((channel = 'batch' and batch_id is not null)
                                                                        or (channel = 'instant' and provider_ref is not null))))
);
create index payouts_user_idx on finance.payouts (user_id, created_at desc);
create index payouts_batch_idx on finance.payouts (batch_id);
create index payouts_requested_idx on finance.payouts (created_at) where status = 'requested';

alter table finance.payouts enable row level security;
create policy payouts_iss on finance.payouts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy payouts_own_read on finance.payouts for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy payouts_finance_read on finance.payouts for select to authenticated using ((select ops.has_admin('admin_finance')));  -- policy:core.admin-aal2
grant select on finance.payouts to authenticated;
