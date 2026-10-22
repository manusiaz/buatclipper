-- E-30 undangan anggota org (F-B01, alur 5): token acak dibagikan brand_owner sendiri, hanya hash-nya yang disimpan. Tanpa email.
create table market.org_invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references market.organizations (id),
  role market.org_role not null,
  token_hash bytea not null check (octet_length(token_hash) = 32),
  expires_at timestamptz not null,
  accepted_by uuid,
  accepted_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  constraint org_invites_token_unique unique (token_hash),
  constraint org_invites_expiry check (expires_at > created_at),
  constraint org_invites_accept_complete check ((accepted_by is null) = (accepted_at is null))
);
create index org_invites_org_idx on market.org_invites (org_id);
create index org_invites_accepted_by_idx on market.org_invites (accepted_by);
create index org_invites_created_by_idx on market.org_invites (created_by);

alter table market.org_invites enable row level security;
create policy org_invites_iss on market.org_invites as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy org_invites_owner_read on market.org_invites for select to authenticated  -- policy:core.org-role
  using ((select ops.is_org_member(org_id, 'brand_owner')));
grant select (id, org_id, role, expires_at, accepted_by, accepted_at, created_by, created_at) on market.org_invites to authenticated;
