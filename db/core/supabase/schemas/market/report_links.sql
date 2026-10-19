-- E-33 link laporan read-only (F-B09) untuk dibagikan brand ke atasannya: {domain}/r/[token] tanpa login.
-- Token acak hanya dikembalikan sekali saat dibuat; yang disimpan sha256-nya.
create table market.report_links (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references market.campaigns (id),
  token_hash bytea not null check (octet_length(token_hash) = 32),
  created_by uuid not null references market.profiles (id),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint report_links_token_unique unique (token_hash)
);
create index report_links_campaign_idx on market.report_links (campaign_id);
create index report_links_created_by_idx on market.report_links (created_by);

alter table market.report_links enable row level security;
create policy report_links_iss on market.report_links as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy report_links_org_read on market.report_links for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
grant select (id, campaign_id, created_by, expires_at, revoked_at, created_at) on market.report_links to authenticated;
