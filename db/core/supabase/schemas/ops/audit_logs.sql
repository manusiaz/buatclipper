-- E-24 (core): semua aksi admin/finance/config (F-A11). Append-only. Akses PII tercatat terpisah di identity.
create table ops.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  target text not null,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
create index audit_logs_target_idx on ops.audit_logs (target, at desc);
create index audit_logs_actor_idx on ops.audit_logs (actor_id, at desc);
create trigger audit_logs_append_only before update or delete on ops.audit_logs
  for each row execute function ops.reject_mutation();

alter table ops.audit_logs enable row level security;
create policy audit_logs_iss on ops.audit_logs as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy audit_logs_super_read on ops.audit_logs for select to authenticated using ((select ops.has_admin('admin_super')));  -- policy:core.admin-aal2
grant select on ops.audit_logs to authenticated;
