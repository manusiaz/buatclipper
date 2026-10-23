-- View Data API creator (security_invoker: RLS tabel berlaku).
create view api.profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path, created_at from market.profiles;
create view api.my_profile with (security_invoker = true) as
  select id, username, display_name, avatar_path, trust_score, status, suspended_until, created_at
  from market.profiles where id = (select auth.uid());
grant select on api.profiles to anon, authenticated;
grant select on api.my_profile to authenticated;
-- Claim milik sendiri (replika admin): Edge Function creator/social memeriksa claim sebelum daftar video.
create view api.claims with (security_invoker = true) as
  select id, campaign_id, user_id, status, expires_at, created_at from market.claims;
grant select on api.claims to authenticated;
-- Config replika admin; kunci public.* terbaca semua (flag platform untuk Edge Function social/track-worker).
create view api.settings with (security_invoker = true) as
  select key, value, updated_at from ops.settings;
grant select on api.settings to anon, authenticated;
