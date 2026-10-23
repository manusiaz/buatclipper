-- View Data API creator (security_invoker: RLS tabel berlaku).
create view api.profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path, created_at from market.profiles;
create view api.my_profile with (security_invoker = true) as
  select id, username, display_name, avatar_path, trust_score, status, suspended_until, created_at
  from market.profiles where id = (select auth.uid());
grant select on api.profiles to anon, authenticated;
grant select on api.my_profile to authenticated;
