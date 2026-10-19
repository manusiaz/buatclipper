-- E-23 notifikasi in-app (clipper, brand, admin). User hanya membaca miliknya dan menandai sudah dibaca.
create table ops.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references market.profiles (id),
  event text not null check (event ~ '^[a-z_]+(\.[a-z_]+)+$'),
  payload jsonb not null default '{}',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on ops.notifications (user_id, created_at desc);
create index notifications_unread_idx on ops.notifications (user_id) where read_at is null;

alter table ops.notifications enable row level security;
create policy notifications_iss on ops.notifications as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy notifications_own_read on ops.notifications for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy notifications_own_mark_read on ops.notifications for update to authenticated  -- policy:core.rls-self
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, update (read_at) on ops.notifications to authenticated;

-- E-34 preferensi email promosi (campaign baru, broadcast). Email transaksional (OTP, payout, KYC) tidak bisa dimatikan.
create table ops.notification_prefs (
  user_id uuid primary key references market.profiles (id),
  email_promotions boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table ops.notification_prefs enable row level security;
create policy notification_prefs_iss on ops.notification_prefs as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy notification_prefs_own on ops.notification_prefs for all to authenticated  -- policy:core.rls-self
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert, update (email_promotions, updated_at) on ops.notification_prefs to authenticated;
