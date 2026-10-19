-- E-24 (identity): log akses & perubahan data ber-PII. Append-only.
create table member.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null check (action ~ '^[a-z_]+(\.[a-z_]+)+$'),
  target text not null,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
create index audit_logs_target_idx on member.audit_logs (target, at desc);
create trigger audit_logs_append_only before update or delete on member.audit_logs
  for each row execute function member.reject_mutation();

alter table member.audit_logs enable row level security;
create policy audit_logs_super_read on member.audit_logs for select to authenticated  -- policy:identity.admin-aal2
  using ((select member.is_admin('admin_super')));
grant select on member.audit_logs to authenticated;
