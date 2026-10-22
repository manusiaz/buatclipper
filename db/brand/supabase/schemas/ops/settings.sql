-- E-25 config (salinan lokal: issuer dari seed, key lain direplika dari admin lewat event settings.changed). Kunci public.* boleh dibaca semua (min withdraw, link komunitas, banner); sisanya hanya admin.
-- Diubah lewat api.update_config (admin, aal2). auth.identity_issuer = issuer identity per environment (§15.6).
create table ops.settings (
  key text primary key check (key ~ '^[a-z_]+(\.[a-z_0-9]+)+$'),
  value jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

alter table ops.settings enable row level security;
create policy settings_iss on ops.settings as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy settings_public_read on ops.settings for select to anon, authenticated using (key like 'public.%');  -- policy:core.public-read
create policy settings_admin_read on ops.settings for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on ops.settings to anon, authenticated;
