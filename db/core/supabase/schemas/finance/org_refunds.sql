-- E-35 refund sisa budget ke brand (D-09 opsi b, F-B04). Rollover (opsi a) cukup jurnal ke akun org_credit, tanpa baris di sini.
-- Diajukan brand_owner/brand_finance (aal2), disetujui admin_finance lain, dibayar manual; bukti transfer di payout-proofs (identity).
create table finance.org_refunds (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references market.organizations (id),
  campaign_id uuid references market.campaigns (id),
  amount numeric(18, 2) not null check (amount > 0),
  transfer_fee numeric(18, 2) not null default 0 check (transfer_fee >= 0),
  status text not null default 'requested' check (status in ('requested', 'approved', 'paid', 'cancelled')),
  requested_by uuid not null,
  approved_by uuid,
  bank_ref text,
  proof_ref text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  constraint org_refunds_idempotency_unique unique (idempotency_key),
  constraint org_refunds_fee_below_amount check (transfer_fee < amount),
  constraint org_refunds_two_person check (approved_by is null or approved_by <> requested_by),
  constraint org_refunds_approved check (status not in ('approved', 'paid') or approved_by is not null),
  constraint org_refunds_paid_complete check (status <> 'paid' or (paid_at is not null and proof_ref is not null))
);
create index org_refunds_org_idx on finance.org_refunds (org_id, created_at desc);
create index org_refunds_campaign_idx on finance.org_refunds (campaign_id);

alter table finance.org_refunds enable row level security;
create policy org_refunds_iss on finance.org_refunds as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy org_refunds_org_read on finance.org_refunds for select to authenticated  -- policy:core.org-role
  using ((select ops.is_org_member(org_id, 'brand_owner', 'brand_finance')));
create policy org_refunds_finance_read on finance.org_refunds for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_finance')));
grant select on finance.org_refunds to authenticated;
