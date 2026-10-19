-- E-38 tautan agency → org klien (F-B12). Anggota agency memegang role yang sama di org klien (ops.org_role).
-- Dibuat agency, disetujui brand_owner org klien; dicabut = revoked_at.
create table market.org_links (
  agency_org_id uuid not null references market.organizations (id),
  client_org_id uuid not null references market.organizations (id),
  approved_by uuid,
  approved_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (agency_org_id, client_org_id),
  constraint org_links_not_self check (agency_org_id <> client_org_id),
  constraint org_links_approval_complete check ((approved_by is null) = (approved_at is null))
);
create index org_links_client_idx on market.org_links (client_org_id);

alter table market.org_links enable row level security;
create policy org_links_iss on market.org_links as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy org_links_party_read on market.org_links for select to authenticated  -- policy:core.org-role
  using ((select ops.is_org_member(agency_org_id)) or (select ops.is_org_member(client_org_id, 'brand_owner')));
create policy org_links_admin_read on market.org_links for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.org_links to authenticated;
