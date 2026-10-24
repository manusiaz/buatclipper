-- Profil milik creator. Kode error: kepala ops/_base.sql.

-- Alur 1: buat profil E-01 dari JWT identity, atau perbarui username & nama tampilan kalau sudah ada (profil anggota brand
-- dibuat lebih dulu lewat event profile.ensure, alur 5). Dipanggil onboarding SEBELUM consent dicatat (consent = penanda
-- onboarding selesai). p_avatar_path: objek bucket avatars di folder {uid}/ (diunggah lebih dulu); null = avatar lama.
-- Referral (F-C16, bonus = uang) dicatat admin lewat event referral.record, hanya untuk profil baru.
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
  -- deleted_ = nama profil yang dihapus (profile.anonymize): direservasi, kalau tidak anonimisasi bentrok unik dan antrean
  -- admin → creator macet
  if lower(btrim(p_username)) like 'deleted\_%' then
    perform market.fail('username_taken', lower(btrim(p_username)), '23505');
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
  if was_new and nullif(btrim(p_referral_code), '') is not null then
    perform bus.emit('admin', 'referral.record', jsonb_build_object('user_id', uid, 'code', lower(btrim(p_referral_code))));
  end if;
  return query select pr.id, pr.username, pr.display_name, was_new from market.profiles pr where pr.id = uid;
end $$;
revoke execute on function api.ensure_profile(text, text, text, text) from public;
grant execute on function api.ensure_profile(text, text, text, text) to authenticated;

-- Event profile.ensure (anggota brand yang belum onboarding, alur 5): profil minimal; username sementara m_<12 hex id> bila
-- tidak diberikan/terpakai; ensure_profile memperbaruinya saat onboarding. Profil yang ada tidak diubah.
create function bus_in.profile_ensure(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
  uname text := lower(btrim(p ->> 'username'));
begin
  if exists (select 1 from market.profiles x where x.id = v_user) then
    return;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,30}$' or uname like 'deleted\_%' or exists (select 1 from market.profiles x where x.username = uname) then
    uname := 'm_' || substr(replace(v_user::text, '-', ''), 1, 12);
  end if;
  while exists (select 1 from market.profiles x where x.username = uname) loop
    uname := 'm_' || substr(md5(random()::text), 1, 12);
  end loop;
  insert into market.profiles (id, username, display_name)
  values (v_user, uname, coalesce(nullif(left(btrim(p ->> 'display_name'), 50), ''), 'Anggota brand'));
end $$;

-- Event profile.anonymize (hapus akun, alur 12 — status closed & submisi diputus admin): isi profil dikosongkan, token sosmed
-- dihapus dari Vault, akun sosmed tanpa submisi dihapus, sisanya diputus permanen (UNIQUE platform+external_id tetap
-- mencegah akun yang sama dipakai ulang). File avatar dihapus creator/bridge.
create function bus_in.profile_anonymize(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
begin
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 22), display_name = 'Akun dihapus', avatar_path = null
   where id = v_user;
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = v_user);
  delete from tracking.social_accounts a
   where a.user_id = v_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = v_user;
end $$;

-- Event social.reset (§4 admin_support "reset koneksi akun", audit di admin): token dicabut (Vault dihapus, status revoked),
-- tracking berhenti, clipper dikabari untuk menyambung ulang akun yang sama. Akun yang sudah diputus tidak diubah.
create function bus_in.social_reset(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  a tracking.social_accounts;
begin
  select * into a from tracking.social_accounts x where x.id = (p ->> 'account_id')::uuid for update;
  if not found or a.status = 'disconnected' then
    return;
  end if;
  delete from vault.secrets v where v.id = a.token_ref;
  update tracking.social_accounts set status = 'revoked', token_ref = null where id = a.id;
  perform ops.notify(a.user_id, 'social.token_expired', jsonb_build_object('account_id', a.id, 'platform', a.platform,
                                                                          'handle', a.handle, 'paused_count', tracking.paused_count(a.id)));
end $$;
revoke execute on function bus_in.profile_ensure(jsonb), bus_in.profile_anonymize(jsonb), bus_in.social_reset(jsonb) from public;
