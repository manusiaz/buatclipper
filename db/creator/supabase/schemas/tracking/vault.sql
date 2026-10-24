-- vault.social-tokens: token OAuth sosmed disimpan di Supabase Vault creator, tidak pernah plaintext di tabel.
-- Hanya Edge Function creator/social dan refresh-tokens (service role) yang memanggil fungsi ini.
create function api.store_social_token(p_account_id uuid, p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
  st text;
begin
  select a.token_ref, a.status into sid, st from tracking.social_accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'akun sosmed % tidak ada', p_account_id using errcode = 'P0002';
  end if;
  -- Akun dicabut (reset admin / izin dicabut) atau diputus hanya hidup lagi lewat sambung ulang pemilik (upsert → verified dulu);
  -- refresh token yang sedang jalan tidak boleh menulis token baru (R34-1).
  if st not in ('verified', 'token_expired') then
    return null;
  end if;
  if sid is null then
    sid := vault.create_secret(p_token, 'social:' || p_account_id::text, 'token OAuth sosmed');
    update tracking.social_accounts set token_ref = sid where id = p_account_id;
  else
    perform vault.update_secret(sid, p_token);
  end if;
  update tracking.social_accounts set status = 'verified', verified_at = now()
   where id = p_account_id and status in ('token_expired', 'verified');
  return sid;
end $$;
revoke execute on function api.store_social_token(uuid, text) from public;
grant execute on function api.store_social_token(uuid, text) to service_role;
