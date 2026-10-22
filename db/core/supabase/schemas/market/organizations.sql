-- E-02 org brand: replika dari project brand (pemilik data); kolom milik admin: fee_rule_id. Badan usaha: nama legal, NPWP, alamat
-- = data badan. Perorangan: NPWP = NIK pemilik dan nama/alamat pribadi = PII, jadi kolomnya wajib kosong; datanya dari KYC (E-05).
create table market.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 100),
  org_type text not null check (org_type in ('badan', 'perorangan')),
  legal_name text,
  npwp text check (npwp ~ '^[0-9]{15,16}$'),
  address text,
  is_agency boolean not null default false,
  fee_rule_id uuid references finance.fee_rules (id),
  status market.org_status not null default 'pending_verification',
  verified_by uuid,
  verified_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  constraint organizations_perorangan_no_pii check (org_type = 'badan' or (legal_name is null and npwp is null and address is null)),
  constraint organizations_verified_complete check (status <> 'verified' or (verified_at is not null and verified_by is not null))
);
create index organizations_fee_rule_idx on market.organizations (fee_rule_id);

alter table market.organizations enable row level security;
create policy organizations_iss on market.organizations as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy organizations_member_read on market.organizations for select to authenticated using ((select ops.is_org_member(id)));  -- policy:core.rls-org
create policy organizations_admin_read on market.organizations for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.organizations to authenticated;
