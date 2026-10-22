-- E-03 anggota org + role brand: replika dari project brand (pemilik data; aturan ≥ 1 brand_owner di sana). Kolom milik admin: tidak ada.
create table market.org_members (
  org_id uuid not null references market.organizations (id),
  user_id uuid not null references market.profiles (id),
  role market.org_role not null,
  added_by uuid,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index org_members_user_idx on market.org_members (user_id);

alter table market.org_members enable row level security;
create policy org_members_iss on market.org_members as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy org_members_same_org_read on market.org_members for select to authenticated using ((select ops.is_org_member(org_id)));  -- policy:core.rls-org
create policy org_members_admin_read on market.org_members for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.org_members to authenticated;
