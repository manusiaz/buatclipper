-- E-24 (brand): aksi admin & pemilik org di data brand. Salinan lokal; tiap baris diteruskan ke pusat audit admin (audit.log). Append-only. Akses PII tercatat terpisah di identity.
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
create function ops.reject_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $$;
create trigger audit_logs_append_only before update or delete on ops.audit_logs
  for each row execute function ops.reject_mutation();

create function ops.forward_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform bus.emit('admin', 'audit.log', to_jsonb(new) - 'id');
  return null;
end $$;
create trigger audit_logs_forward after insert on ops.audit_logs for each row execute function ops.forward_audit();

alter table ops.audit_logs enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)
