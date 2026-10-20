-- Policy storage core. Bucket = baris storage.buckets (config.toml lokal, `supabase seed buckets --linked` di hosted):
--   campaign-covers (publik)  path {org_id}/{campaign_id}/…   cover card & OG image
--   campaign-assets (privat)  path {org_id}/{campaign_id}/…   aset brief, signed URL untuk user yang bisa melihat campaign;
--                             {org_id}/{campaign_id}/internal/… brief mentah brand (paket managed): anggota org + admin saja
--   avatars (publik)          path {user_id}/…                foto profil (F-C01)
--   invoice-docs (privat)     path {org_id}/{invoice_id}/…    faktur pajak PDF: admin_finance unggah, brand_owner/brand_finance unduh
create policy campaign_files_write on storage.objects for insert to authenticated  -- policy:core.org-role
  with check (bucket_id in ('campaign-covers', 'campaign-assets')
              and ((select ops.is_org_member(((storage.foldername(name))[1])::uuid, 'brand_owner', 'brand_manager'))
                   or (select ops.has_admin('admin_ops'))));
create policy campaign_assets_read on storage.objects for select to authenticated  -- policy:core.inherit-parent
  using (bucket_id = 'campaign-assets'
         and exists (select 1 from market.campaigns c where c.id = ((storage.foldername(name))[2])::uuid
                     and ((storage.foldername(name))[3] is distinct from 'internal'
                          or (select ops.is_org_member(c.org_id)) or (select ops.has_admin()))));
create policy avatars_own_write on storage.objects for insert to authenticated  -- policy:core.rls-self
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy avatars_own_update on storage.objects for update to authenticated  -- policy:core.rls-self
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy invoice_docs_write on storage.objects for insert to authenticated  -- policy:core.admin-aal2
  with check (bucket_id = 'invoice-docs' and (select ops.has_admin('admin_finance')));
create policy invoice_docs_read on storage.objects for select to authenticated  -- policy:core.org-role
  using (bucket_id = 'invoice-docs'
         and ((select ops.is_org_member(((storage.foldername(name))[1])::uuid, 'brand_owner', 'brand_finance'))
              or (select ops.has_admin('admin_finance'))));
