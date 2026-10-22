-- Policy storage admin. Bucket = baris storage.buckets (config.toml lokal, `supabase seed buckets --linked` di hosted).
-- Cover & aset campaign ada di storage project brand (db/brand market/storage.sql).
--   avatars (publik)          path {user_id}/…                foto profil (F-C01)
--   invoice-docs (privat)     path {org_id}/{invoice_id}/…    faktur pajak PDF: admin_finance unggah, brand_owner/brand_finance unduh
create policy avatars_own_write on storage.objects for insert to authenticated  -- policy:core.rls-self
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy avatars_own_update on storage.objects for update to authenticated  -- policy:core.rls-self
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy invoice_docs_write on storage.objects for insert to authenticated  -- policy:core.admin-aal2
  with check (bucket_id = 'invoice-docs' and (select ops.has_admin('admin_finance')));
create policy invoice_docs_delete on storage.objects for delete to authenticated  -- policy:core.admin-aal2
  using (bucket_id = 'invoice-docs' and (select ops.has_admin('admin_finance')));
create policy invoice_docs_read on storage.objects for select to authenticated  -- policy:core.org-role
  using (bucket_id = 'invoice-docs'
         and ((select ops.is_org_member(((storage.foldername(name))[1])::uuid, 'brand_owner', 'brand_finance'))
              or (select ops.has_admin('admin_finance'))));
