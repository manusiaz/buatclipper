-- Policy storage creator. Bucket (config.toml): avatars (publik) path {user_id}/… foto profil (F-C01).
create policy avatars_own_write on storage.objects for insert to authenticated  -- policy:core.rls-self
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
create policy avatars_own_update on storage.objects for update to authenticated  -- policy:core.rls-self
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'sub'));
