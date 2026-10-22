-- Replika org brand (pemilik: project brand, bus.replicate kolom 'creator:...'): nama brand di katalog campaign, status org untuk
-- campaign yang boleh tayang, anggota & tautan agency untuk aturan "anggota brand tidak bisa claim campaign org-nya sendiri".
-- Tanpa data badan (nama legal, NPWP, alamat). Hanya ditulis bus.apply_row.
create table market.organizations (
  id uuid primary key,
  name text not null,
  is_agency boolean not null default false,
  status market.org_status not null,
  verified_at timestamptz,
  created_at timestamptz not null
);

create table market.org_members (
  org_id uuid not null references market.organizations (id) on delete cascade,
  user_id uuid not null,
  role market.org_role not null,
  created_at timestamptz not null,
  primary key (org_id, user_id)
);
create index org_members_user_idx on market.org_members (user_id);

create table market.org_links (
  agency_org_id uuid not null references market.organizations (id) on delete cascade,
  client_org_id uuid not null references market.organizations (id) on delete cascade,
  approved_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null,
  primary key (agency_org_id, client_org_id)
);
create index org_links_client_idx on market.org_links (client_org_id);

alter table market.organizations enable row level security;  -- policy:core.definer-only (replika; diekspos lewat api di 4DB-4)
alter table market.org_members enable row level security;  -- policy:core.definer-only
alter table market.org_links enable row level security;  -- policy:core.definer-only
