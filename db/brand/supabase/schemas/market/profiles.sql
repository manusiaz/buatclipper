-- Replika E-01 profil (read-only; pemilik di project profil): nama & avatar anggota tim/review, status untuk cek akun aktif.
create table market.profiles (
  id uuid primary key,
  username text,
  display_name text,
  avatar_path text,
  status market.profile_status not null default 'active',
  suspended_until timestamptz,
  trust_score smallint not null default 50  -- visibilitas campaign level (tidak diekspos ke browser)
);

alter table market.profiles enable row level security;
create policy profiles_iss on market.profiles as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy profiles_public_read on market.profiles for select to anon, authenticated using (true);  -- policy:core.public-read
grant select (id, username, display_name, avatar_path) on market.profiles to anon, authenticated;
grant select (trust_score) on market.profiles to authenticated;  -- policy campaigns_public_auth (level); api.profiles tidak memuatnya
