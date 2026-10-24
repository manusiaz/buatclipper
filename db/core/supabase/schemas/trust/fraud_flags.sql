-- E-20 fraud flag (sinyal FR-01–FR-11, §12). Satu flag terbuka per (target, sinyal). Hanya admin yang melihat.
create table trust.fraud_flags (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('submission', 'profile', 'social_account', 'payout')),
  target_id uuid not null,
  signal text not null check (signal ~ '^FR-[0-9]{2}$'),
  score numeric(5, 2) check (score between 0 and 100),
  status text not null default 'open' check (status in ('open', 'held', 'dismissed', 'actioned')),
  details jsonb not null default '{}',
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint fraud_flags_resolution check ((status in ('open', 'held')) = (resolved_at is null))
);
create unique index fraud_flags_one_open on trust.fraud_flags (target_type, target_id, signal) where status in ('open', 'held');
create index fraud_flags_queue_idx on trust.fraud_flags (status, created_at);

alter table trust.fraud_flags enable row level security;
create policy fraud_flags_iss on trust.fraud_flags as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy fraud_flags_admin_read on trust.fraud_flags for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_moderator', 'admin_finance')));
grant select on trust.fraud_flags to authenticated;
