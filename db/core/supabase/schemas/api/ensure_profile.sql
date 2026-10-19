-- Alur 1: buat profil E-01 dari JWT identity, atau perbarui username & nama tampilan kalau sudah ada (profil anggota brand
-- dibuat admin lebih dulu, alur 5). Dipanggil onboarding SEBELUM consent dicatat: consent = penanda onboarding selesai,
-- jadi kalau langkah ini gagal user tetap kembali ke onboarding, bukan masuk app tanpa profil.
-- p_avatar_path: objek bucket avatars di folder {uid}/ (diunggah lebih dulu); null = avatar lama dipertahankan.
-- Kode: auth:no_session, username_taken, not_eligible:profile_inactive, invalid:avatar_path.
create function api.ensure_profile(p_username text, p_display_name text, p_referral_code text default null,
  p_avatar_path text default null)
returns table (id uuid, username text, display_name text, created boolean)
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  was_new boolean;
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if p_avatar_path is not null and (p_avatar_path not like uid::text || '/%' or p_avatar_path like '%..%') then
    perform market.fail('invalid:avatar_path', 'avatar harus di folder {uid}/', '22023');
  end if;
  begin
    insert into market.profiles as p (id, username, display_name, avatar_path)
    values (uid, lower(btrim(p_username)), btrim(p_display_name), p_avatar_path)
    on conflict on constraint profiles_pkey do update set username = excluded.username, display_name = excluded.display_name,
      avatar_path = coalesce(excluded.avatar_path, p.avatar_path)
      where p.status = 'active'
    returning (xmax = 0) into was_new;
  exception when unique_violation then
    perform market.fail('username_taken', lower(btrim(p_username)), '23505');
  end;
  if was_new is null then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif', '42501');
  end if;
  -- Referral (F-C16) hanya dicatat untuk profil baru; kode tidak dikenal atau milik sendiri diabaikan.
  if was_new and p_referral_code is not null then
    insert into market.referrals (referred_id, referrer_id, code)
    select uid, r.id, r.referral_code from market.profiles r
     where r.referral_code = lower(btrim(p_referral_code)) and r.id <> uid;
  end if;
  return query select pr.id, pr.username, pr.display_name, was_new from market.profiles pr where pr.id = uid;
end $$;
revoke execute on function api.ensure_profile(text, text, text, text) from public;
grant execute on function api.ensure_profile(text, text, text, text) to authenticated;
