-- E-10 aset campaign. File di bucket campaign-covers (cover, publik) atau campaign-assets (privat, signed URL);
-- kind link = URL luar. audience clipper = aset brief untuk clipper, terlihat kalau campaign-nya terlihat (RLS campaigns ikut
-- berlaku di subquery). audience internal = brief mentah/berkas brand untuk tim (paket managed), hanya anggota org + admin;
-- filenya wajib di folder {org_id}/{campaign_id}/internal/ supaya policy storage bisa menutupnya juga.
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

-- Aset campaign yang sudah disetujui tidak berubah lewat replika (pasangan market.campaign_content_frozen): brand mengunci brief dari
-- replika status yang bisa tertinggal (admin → brand macet) — aset baru / hapus dari brand dilewati + alert campaign.content_drift,
-- supaya clipper tidak menerima file yang belum direview. Aset versi yang diajukan tiba lebih dulu (urutan bus per pengirim).
create function market.campaign_assets_frozen() returns trigger
language plpgsql set search_path = '' as $$
declare
  c market.campaigns;
begin
  if current_setting('bus.applying', true) is distinct from 'on' then
    return coalesce(new, old);
  end if;
  select * into c from market.campaigns k where k.id = coalesce(new.campaign_id, old.campaign_id);
  if c.status in ('draft', 'in_review', 'rejected') or c.submitted_version is null then
    return coalesce(new, old);
  end if;
  perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', c.id, 'status', c.status, 'asset', lower(tg_op)));
  return null;
end $$;
create trigger campaign_assets_frozen before insert or delete on market.campaign_assets
  for each row execute function market.campaign_assets_frozen();

alter table market.campaign_assets enable row level security;
create policy campaign_assets_iss on market.campaign_assets as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy campaign_assets_cover_public on market.campaign_assets for select to anon  -- policy:core.public-read
  using (kind = 'cover' and audience = 'clipper' and exists (select 1 from market.campaigns c where c.id = campaign_id));
create policy campaign_assets_visible on market.campaign_assets for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from market.campaigns c where c.id = campaign_id
                 and (audience = 'clipper' or (select ops.is_org_member(c.org_id)) or (select ops.has_admin()))));
grant select on market.campaign_assets to anon, authenticated;
