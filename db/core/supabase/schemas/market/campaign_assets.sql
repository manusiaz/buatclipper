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

-- Aset campaign lewat replika (pasangan market.campaign_content_frozen): brand mengunci brief dari replika status yang bisa tertinggal
-- (admin → brand macet). Sudah disetujui → aset baru / hapus dilewati + alert campaign.content_drift (clipper tidak menerima file
-- yang belum direview). Selagi in_review → review dibatalkan saat itu juga (market.require_resubmit): kenaikan content_version bisa
-- tiba di batch berikutnya, sesudah persetujuan, lalu ikut dibekukan.
create function market.campaign_assets_frozen() returns trigger
language plpgsql set search_path = '' as $$
declare
  c market.campaigns;
begin
  -- BEFORE INSERT jalan sebelum ON CONFLICT: aset yang sudah ada (putar ulang identik, mis. bus.resync) bukan perubahan
  if current_setting('bus.applying', true) is distinct from 'on'
     or (tg_op = 'INSERT' and exists (select 1 from market.campaign_assets x where x.id = new.id)) then
    return coalesce(new, old);
  end if;
  select * into c from market.campaigns k where k.id = coalesce(new.campaign_id, old.campaign_id) for update;
  if c.status = 'in_review' then
    begin  -- applying dimatikan sementara: status draft ikut direplika ke brand & creator; tidak pernah raise (antrean jalan)
      perform set_config('bus.applying', 'off', true);
      perform market.require_resubmit(c);
      perform set_config('bus.applying', 'on', true);
    exception when others then
      perform set_config('bus.applying', 'on', true);
      perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', c.id, 'error', sqlerrm));
    end;
    return coalesce(new, old);
  end if;
  if c.status in ('draft', 'rejected') or c.submitted_version is null then
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
