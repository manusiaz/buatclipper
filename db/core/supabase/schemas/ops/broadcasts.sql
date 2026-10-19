-- E-42 broadcast pengumuman ke segmen clipper (F-A12). Dikirim job broadcast-dispatch lewat enqueue_notification
-- (event broadcast.sent = promosi, jadi email ikut preferensi E-34; push lewat bridge identity).
create table ops.broadcasts (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 1 and 2000),
  segment jsonb not null default '{}' check (jsonb_typeof(segment) = 'object'),
  channels text[] not null default '{in_app}' check (channels <@ array['in_app', 'email', 'push'] and cardinality(channels) >= 1),
  created_by uuid not null,
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  recipient_count integer check (recipient_count >= 0),
  created_at timestamptz not null default now(),
  constraint broadcasts_sent_has_count check ((sent_at is null) = (recipient_count is null))
);
create index broadcasts_pending_idx on ops.broadcasts (scheduled_at) where sent_at is null;

alter table ops.broadcasts enable row level security;
create policy broadcasts_iss on ops.broadcasts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy broadcasts_admin_read on ops.broadcasts for select to authenticated using ((select ops.has_admin('admin_ops')));  -- policy:core.admin-aal2
grant select on ops.broadcasts to authenticated;
