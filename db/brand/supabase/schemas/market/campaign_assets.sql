-- E-10 aset campaign (pemilik: brand). File di bucket campaign-covers (cover, publik) atau campaign-assets (privat, signed URL)
-- storage project brand; kind link = URL luar. audience internal = brief mentah (paket managed), hanya anggota org + admin, file
-- di folder {org_id}/{campaign_id}/internal/. Direplika ke admin (review & katalog).
create table market.campaign_assets (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  kind text not null check (kind in ('cover', 'video', 'image', 'audio', 'document', 'link')),
  storage_path text,
  url text check (url ~ '^https://'),
  size_bytes bigint check (size_bytes >= 0),
  audience text not null default 'clipper' check (audience in ('clipper', 'internal')),
  created_at timestamptz not null default now(),
  constraint campaign_assets_one_source check ((storage_path is null) <> (url is null)),
  constraint campaign_assets_link_is_url check ((kind = 'link') = (url is not null)),
  constraint campaign_assets_internal_folder check (storage_path is null
                                                    or (split_part(storage_path, '/', 3) = 'internal') = (audience = 'internal')),
  constraint campaign_assets_cover_public check (kind <> 'cover' or audience = 'clipper')
);
create index campaign_assets_campaign_idx on market.campaign_assets (campaign_id);
create trigger campaign_assets_replicate after insert or update or delete on market.campaign_assets for each row
  execute function bus.replicate('admin:campaign_id,kind,storage_path,url,size_bytes,audience,created_at');

alter table market.campaign_assets enable row level security;
create policy campaign_assets_iss on market.campaign_assets as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy campaign_assets_cover_public on market.campaign_assets for select to anon  -- policy:core.public-read
  using (kind = 'cover' and audience = 'clipper' and exists (select 1 from market.campaigns c where c.id = campaign_id));
create policy campaign_assets_visible on market.campaign_assets for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from market.campaigns c where c.id = campaign_id
                 and (audience = 'clipper' or (select ops.is_org_member(c.org_id)) or (select ops.has_admin()))));
grant select on market.campaign_assets to anon, authenticated;
