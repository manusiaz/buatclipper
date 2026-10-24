-- E-04 akun sosmed terhubung lewat OAuth (F-C02) — replika dari project creator (pemilik + token Vault + batas akun per
-- platform); tanpa token_ref. Dibaca claim_check, fraud, broadcast, dan tampilan admin. Reset akun oleh admin = event social.reset.
create table tracking.social_accounts (
  id uuid primary key default gen_random_uuid(),  -- default hanya untuk fixture uji; replika membawa id creator
  user_id uuid not null references market.profiles (id),
  platform market.platform not null,
  external_id text not null,
  handle text not null,
  status text not null default 'verified' check (status in ('verified', 'token_expired', 'revoked', 'disconnected')),
  followers integer check (followers >= 0),
  platform_created_at timestamptz,
  verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint social_accounts_one_owner unique (platform, external_id),
  constraint social_accounts_key unique (id, user_id, platform)
);
create index social_accounts_user_idx on tracking.social_accounts (user_id, platform);

alter table tracking.social_accounts enable row level security;
create policy social_accounts_iss on tracking.social_accounts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy social_accounts_own_read on tracking.social_accounts for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy social_accounts_admin_read on tracking.social_accounts for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_moderator', 'admin_support')));
grant select on tracking.social_accounts to authenticated;
