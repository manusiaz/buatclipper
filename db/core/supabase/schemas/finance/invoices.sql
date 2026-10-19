-- E-22 invoice brand (F-B04). Total dicek konsisten di database; nomor referensi pembayaran unik (referensi sama ditolak, F-A08).
-- Dibaca brand_owner/brand_finance org itu dan admin_finance; ditulis save_campaign & confirm_invoice_payment.
create table finance.invoices (
  id uuid primary key default gen_random_uuid(),
  number text not null,
  org_id uuid not null references market.organizations (id),
  campaign_id uuid references market.campaigns (id),
  kind text not null default 'campaign' check (kind in ('campaign', 'topup', 'pinned', 'managed_service')),
  subtotal numeric(18, 2) not null check (subtotal >= 0),
  mgmt_fee numeric(18, 2) not null check (mgmt_fee >= 0),
  admin_fee numeric(18, 2) not null check (admin_fee >= 0),
  service_fee numeric(18, 2) not null default 0 check (service_fee >= 0),
  tax numeric(18, 2) not null default 0 check (tax >= 0),
  total numeric(18, 2) not null,
  status text not null default 'issued' check (status in ('issued', 'paid', 'void')),
  payment_channel text check (payment_channel in ('qris', 'transfer')),
  payment_ref text,
  paid_amount numeric(18, 2) check (paid_amount > 0),
  paid_at timestamptz,
  confirmed_by uuid,
  faktur_no text,
  issued_at timestamptz not null default now(),
  due_at timestamptz,
  pin_until timestamptz,
  constraint invoices_number_unique unique (number),
  constraint invoices_payment_ref_unique unique (payment_ref),
  constraint invoices_faktur_unique unique (faktur_no),
  constraint invoices_total_consistent check (total = subtotal + mgmt_fee + admin_fee + service_fee + tax),
  constraint invoices_campaign_kinds check (kind not in ('campaign', 'topup', 'pinned') or campaign_id is not null),
  constraint invoices_pinned_has_period check ((kind = 'pinned') = (pin_until is not null)),
  constraint invoices_paid_complete check (status <> 'paid' or (payment_ref is not null and paid_amount is not null
                                           and paid_at is not null and confirmed_by is not null and payment_channel is not null))
);
create index invoices_org_idx on finance.invoices (org_id, issued_at desc);
create index invoices_campaign_idx on finance.invoices (campaign_id);

alter table finance.invoices enable row level security;
create policy invoices_iss on finance.invoices as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy invoices_org_billing_read on finance.invoices for select to authenticated  -- policy:core.org-role
  using ((select ops.is_org_member(org_id, 'brand_owner', 'brand_finance')));
create policy invoices_finance_read on finance.invoices for select to authenticated using ((select ops.has_admin('admin_finance')));  -- policy:core.admin-aal2
grant select on finance.invoices to authenticated;
