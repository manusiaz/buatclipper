-- E-01 profil publik clipper/anggota brand. id = sub JWT identity (auth.users.id di project identity), tanpa FK lintas DB.
-- Tanpa PII: tidak ada email, HP, nama KTP. Dibuat/diubah lewat api.ensure_profile (alur 1); status diubah fraud queue.
create table market.profiles (
  id uuid primary key,
  username text not null check (username ~ '^[a-z0-9_.]{3,30}$'),
  display_name text not null check (char_length(display_name) between 1 and 50),
  avatar_path text,
  trust_score smallint not null default 50 check (trust_score between 0 and 100),
  status market.profile_status not null default 'active',
  suspended_until timestamptz,
  referral_code text check (referral_code ~ '^[a-z0-9]{8}$'),
  created_at timestamptz not null default now(),
  constraint profiles_username_unique unique (username),
  constraint profiles_referral_code_unique unique (referral_code),
  constraint profiles_avatar_own_folder check (avatar_path is null or avatar_path like id::text || '/%'),
  constraint profiles_suspend_has_until check (status <> 'suspended' or suspended_until is not null)
);

-- Replika profil publik ke brand (anggota tim, nama clipper di review, trust_score untuk visibilitas campaign level). Referral tetap di admin.
create trigger profiles_replicate after insert or update or delete on market.profiles for each row
  execute function bus.replicate('brand:username,display_name,avatar_path,status,suspended_until,trust_score');

alter table market.profiles enable row level security;
create policy profiles_iss on market.profiles as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy profiles_public_read on market.profiles for select to anon, authenticated using (true);  -- policy:core.public-read
grant select (id, username, display_name, avatar_path, created_at) on market.profiles to anon;
grant select on market.profiles to authenticated;
