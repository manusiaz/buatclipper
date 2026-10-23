-- Policy storage admin. Bucket = baris storage.buckets (config.toml lokal, `supabase seed buckets --linked` di hosted).
-- Cover & aset campaign di storage project brand, avatar di project creator (market/storage.sql masing-masing).
--   invoice-docs (privat)     path {org_id}/{invoice_id}/…    faktur pajak PDF: admin_finance unggah, brand_owner/brand_finance unduh
create policy invoice_docs_write on storage.objects for insert to authenticated  -- policy:core.admin-aal2
  with check (bucket_id = 'invoice-docs' and (select ops.has_admin('admin_finance')));
create policy invoice_docs_delete on storage.objects for delete to authenticated  -- policy:core.admin-aal2
  using (bucket_id = 'invoice-docs' and (select ops.has_admin('admin_finance')));
create policy invoice_docs_read on storage.objects for select to authenticated  -- policy:core.org-role
  using (bucket_id = 'invoice-docs'
         and ((select ops.is_org_member(((storage.foldername(name))[1])::uuid, 'brand_owner', 'brand_finance'))
              or (select ops.has_admin('admin_finance'))));
