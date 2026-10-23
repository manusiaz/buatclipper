-- E-01 profil publik clipper/anggota brand (pemilik: project creator). id = sub JWT identity, tanpa FK lintas DB. Tanpa PII.
-- Isi (username, nama tampilan, avatar) ditulis api.ensure_profile & event profile.ensure (anggota brand) / profile.anonymize
-- (hapus akun); direplika ke admin & brand. Kolom milik admin (replika): status, suspended_until, trust_score (fraud, sanksi).
create table market.profiles (
  id uuid primary key,
  username text not null check (username ~ '^[a-z0-9_.]{3,30}$'),
  display_name text not null check (char_length(display_name) between 1 and 50),
  avatar_path text,
  created_at timestamptz not null default now(),
  -- milik admin (replika)
  status market.profile_status not null default 'active',
  suspended_until timestamptz,
  trust_score smallint not null default 50,
  constraint profiles_username_unique unique (username),
  constraint profiles_avatar_own_folder check (avatar_path is null or avatar_path like id::text || '/%')
);
create trigger profiles_replicate after insert or update or delete on market.profiles for each row
  execute function bus.replicate('admin:username,display_name,avatar_path,created_at', 'brand:username,display_name,avatar_path');

alter table market.profiles enable row level security;
create policy profiles_iss on market.profiles as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy profiles_public_read on market.profiles for select to anon, authenticated using (true);  -- policy:core.public-read
grant select (id, username, display_name, avatar_path, created_at) on market.profiles to anon;
grant select on market.profiles to authenticated;
