-- View Data API brand (security_invoker: RLS tabel berlaku).
create view api.organizations with (security_invoker = true) as
  select id, name, org_type, legal_name, npwp, address, is_agency, status, verified_at, created_at, updated_at from market.organizations;
create view api.org_members with (security_invoker = true) as
  select org_id, user_id, role, created_at from market.org_members;
create view api.org_invites with (security_invoker = true) as
  select id, org_id, role, expires_at, accepted_by, accepted_at, created_by, created_at from market.org_invites;
create view api.org_links with (security_invoker = true) as
  select agency_org_id, client_org_id, approved_by, approved_at, revoked_at, created_at from market.org_links;
create view api.profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path from market.profiles;
grant select on api.organizations, api.org_members, api.org_invites, api.org_links to authenticated;
grant select on api.profiles to anon, authenticated;
