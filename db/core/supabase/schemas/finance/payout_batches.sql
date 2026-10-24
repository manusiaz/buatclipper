-- E-26 batch transfer mingguan. Aturan dua orang ditegakkan constraint: penyetuju ≠ pembuat (§4, alur 3).
-- file_ref = CSV di bucket pii-exports (identity), tanpa FK lintas DB.
create table finance.payout_batches (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null,
  approved_by uuid,
  status text not null default 'draft' check (status in ('draft', 'approved', 'exported', 'paid', 'closed')),
  cutoff_at timestamptz not null,
  total numeric(18, 2) not null default 0 check (total >= 0),
  count integer not null default 0 check (count >= 0),
  file_ref text,
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint payout_batches_two_person check (approved_by is null or approved_by <> created_by),
  constraint payout_batches_approved check (status = 'draft' or approved_by is not null),
  constraint payout_batches_exported_has_file check (status not in ('exported', 'paid', 'closed') or file_ref is not null)
);
create index payout_batches_status_idx on finance.payout_batches (status, created_at desc);

alter table finance.payout_batches enable row level security;
create policy payout_batches_iss on finance.payout_batches as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy payout_batches_finance_read on finance.payout_batches for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_finance')));
grant select on finance.payout_batches to authenticated;
