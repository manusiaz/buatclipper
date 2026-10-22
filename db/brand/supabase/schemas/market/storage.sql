-- Policy storage brand. Bucket (config.toml):
--   campaign-covers (publik)  path {org_id}/{campaign_id}/…   cover card & OG image
--   campaign-assets (privat)  path {org_id}/{campaign_id}/…   aset brief, signed URL untuk user yang bisa melihat campaign;
--                             {org_id}/{campaign_id}/internal/… brief mentah brand (paket managed): anggota org + admin saja
create policy campaign_files_write on storage.objects for insert to authenticated  -- policy:core.org-role
  with check (bucket_id in ('campaign-covers', 'campaign-assets')
              and ((select ops.is_org_member(((storage.foldername(name))[1])::uuid, 'brand_owner', 'brand_manager'))
                   or (select ops.has_admin('admin_ops'))));
create policy campaign_assets_read on storage.objects for select to authenticated  -- policy:core.inherit-parent
  using (bucket_id = 'campaign-assets'
         and exists (select 1 from market.campaigns c where c.id = ((storage.foldername(name))[2])::uuid
                     and ((storage.foldername(name))[3] is distinct from 'internal'
                          or (select ops.is_org_member(c.org_id)) or (select ops.has_admin()))));
