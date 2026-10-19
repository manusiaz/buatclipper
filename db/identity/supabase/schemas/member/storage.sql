-- policy:identity.storage-private. Bucket (kyc-docs, pii-exports, payout-proofs) = baris storage.buckets: didefinisikan di
-- config.toml untuk lokal dan `supabase seed buckets --linked` untuk project hosted, karena diff schema tidak menangkap DML.
-- kyc-docs: user hanya bisa unggah/baca di folder {user_id}/; reviewer KYC (admin_moderator, aal2) bisa membaca.
-- pii-exports & payout-proofs: tanpa policy untuk user; hanya Edge Function pii-export (service role) yang menulis dan
-- membuat signed URL 15 menit.
create policy kyc_docs_own_insert on storage.objects for insert to authenticated  -- policy:identity.rls-self
  with check (bucket_id = 'kyc-docs' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy kyc_docs_own_read on storage.objects for select to authenticated  -- policy:identity.rls-self
  using (bucket_id = 'kyc-docs' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy kyc_docs_reviewer_read on storage.objects for select to authenticated  -- policy:identity.admin-aal2
  using (bucket_id = 'kyc-docs' and (select member.is_admin('admin_moderator')));
