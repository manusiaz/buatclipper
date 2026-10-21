-- Fungsi service role untuk Edge Function identity (member-data, pii-export, delete-account, admin-auth, disburse, bridge).
-- Browser tidak bisa memanggilnya: EXECUTE hanya untuk service_role (secret key identity). Ciphertext (bytea) keluar apa
-- adanya; dekripsi + HMAC terjadi di Edge Function karena kuncinya secret fungsi, bukan isi database (§15.4).

-- Rekening untuk CSV payout (alur 3) dan disburse (alur 11). Termasuk yang disabled/blocked supaya pemanggil bisa menahan
-- payout dengan alasan yang jelas; baris tombstone (user_id NULL) ikut terbaca dengan user_id NULL → pemilik tidak cocok.
create function api.svc_payout_methods(p_ids uuid[])
returns table (id uuid, user_id uuid, kind text, bank_code text, account_no_enc bytea, account_last4 text,
               enc_key_version smallint, account_name text, disabled_at timestamptz, blocked boolean)
language sql stable security definer set search_path = '' as $$
  select pm.id, pm.user_id, pm.kind, pm.bank_code, pm.account_no_enc, pm.account_last4, pm.enc_key_version,
         pm.account_name, pm.disabled_at, pm.blocked
  from member.payout_methods pm
  where pm.id = any (p_ids);
$$;

-- AB-6 refund org perorangan: rekening bank aktif milik pemilik org, terbaru dulu (pii-export memilih yang lolos cek KYC).
create function api.svc_user_payout_methods(p_user uuid)
returns table (id uuid, user_id uuid, kind text, bank_code text, account_no_enc bytea, account_last4 text,
               enc_key_version smallint, account_name text, disabled_at timestamptz, blocked boolean)
language sql stable security definer set search_path = '' as $$
  select pm.id, pm.user_id, pm.kind, pm.bank_code, pm.account_no_enc, pm.account_last4, pm.enc_key_version,
         pm.account_name, pm.disabled_at, pm.blocked
  from member.payout_methods pm
  where pm.user_id = p_user and pm.kind = 'bank' and pm.disabled_at is null and not pm.blocked
  order by pm.created_at desc;
$$;

-- FR-04: pemegang NIK / rekening yang dicoba dipakai ulang akun lain (payload fraud flag). tombstone = akun ter-ban.
create function api.svc_hash_holder(p_nik_hash bytea, p_bank_code text, p_account_hash bytea)
returns table (user_id uuid, tombstone boolean)
language sql stable security definer set search_path = '' as $$
  select k.user_id, k.user_id is null from member.kyc_records k where p_nik_hash is not null and k.nik_hash = p_nik_hash
  union all
  select pm.user_id, pm.user_id is null from member.payout_methods pm
   where p_account_hash is not null and pm.bank_code = p_bank_code and pm.account_no_hash = p_account_hash
  limit 1;
$$;

-- KYC per user. closed = baris tombstone akun yang sudah dihapus tapi masih wajib disimpan untuk pajak (retain_until):
-- user_id-nya NULL, jadi dicari lewat jejak audit account.close (append-only) supaya rekap PPh 21 tetap bisa dibuat.
create function api.svc_kyc(p_user_ids uuid[])
returns table (user_id uuid, legal_name text, nik_enc bytea, enc_key_version smallint, status member.kyc_status,
               closed boolean)
language sql stable security definer set search_path = '' as $$
  select k.user_id, k.legal_name, k.nik_enc, k.enc_key_version, k.status, false
  from member.kyc_records k
  where k.user_id = any (p_user_ids)
  union all
  select u.id, k.legal_name, k.nik_enc, k.enc_key_version, k.status, true
  from unnest(p_user_ids) as u (id)
  join member.audit_logs a on a.target = 'user:' || u.id and a.action = 'account.close'
  join member.kyc_records k on k.id = (a.after ->> 'kyc_id')::uuid
  where k.user_id is null and k.nik_enc is not null and k.retain_until >= current_date;
$$;

-- Data penerima reward (E-29) untuk export fulfillment (pola alur 3, syarat consent share_with_brand).
create function api.svc_recipients(p_ids uuid[])
returns table (id uuid, user_id uuid, reward_type_id uuid, data_enc bytea, enc_key_version smallint)
language sql stable security definer set search_path = '' as $$
  select r.id, r.user_id, r.reward_type_id, r.data_enc, r.enc_key_version
  from member.recipient_details r
  where r.id = any (p_ids);
$$;

-- Consent aktif. Dokumen legal (ToS/privasi) harus versi terbaru (E-31); kyc/share_with_brand/age_18_plus cukup belum dicabut.
create function api.svc_has_consent(p_user uuid, p_kind text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_kind in ('tos_clipper', 'tos_brand', 'privacy') then member.has_current_consent(p_user, p_kind::member.consent_kind)
    else exists (select 1 from member.consents c
                 where c.user_id = p_user and c.kind = p_kind::member.consent_kind and c.revoked_at is null)
  end;
$$;

-- Role platform target (admin-auth: moderator tidak boleh mem-ban akun admin).
create function api.svc_platform_roles(p_user uuid)
returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(pr.role::text order by pr.role), '{}')
  from member.platform_roles pr
  where pr.user_id = p_user;
$$;

-- F-X01 admin: penerima email alert operasional = admin dengan salah satu role ini.
create function api.svc_admin_ids(p_roles text[])
returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct pr.user_id order by pr.user_id), '{}')
  from member.platform_roles pr
  where pr.role::text = any (p_roles);
$$;

-- Push (alur 4): langganan per user (web push + token Expo app native), buang endpoint/token mati, catat terakhir dipakai.
create function api.svc_push_subscriptions(p_user uuid)
returns table (kind text, endpoint text, p256dh text, auth_secret text, expo_ticket text)
language sql stable security definer set search_path = '' as $$
  select ps.kind, ps.endpoint, ps.p256dh, ps.auth_secret, ps.expo_ticket
  from member.push_subscriptions ps
  where ps.user_id = p_user
  order by ps.created_at;
$$;

create function api.svc_delete_push(p_endpoint text)
returns void
language sql security definer set search_path = '' as $$
  delete from member.push_subscriptions where endpoint = p_endpoint;
$$;

create function api.svc_touch_push(p_endpoint text, p_ticket text default null)
returns void
language sql security definer set search_path = '' as $$
  update member.push_subscriptions set last_used_at = now(), expo_ticket = coalesce(p_ticket, expo_ticket)
  where endpoint = p_endpoint;
$$;

-- Rekonsiliasi ID lintas DB (alur 10). Rekening tombstone (akun dihapus) dihitung hilang karena tidak bisa dipakai lagi.
create function api.svc_check_ids(p_user_ids uuid[], p_method_ids uuid[], p_recipient_refs uuid[])
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'user_ids', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_user_ids) as x (id)
                          where x.id is not null
                            and not exists (select 1 from auth.users u where u.id = x.id)), '[]'::jsonb),
    'method_ids', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_method_ids) as x (id)
                            where x.id is not null
                              and not exists (select 1 from member.payout_methods pm
                                              where pm.id = x.id and pm.user_id is not null)), '[]'::jsonb),
    'recipient_refs', coalesce((select jsonb_agg(distinct x.id order by x.id) from unnest(p_recipient_refs) as x (id)
                                where x.id is not null
                                  and not exists (select 1 from member.recipient_details r where r.id = x.id)), '[]'::jsonb));
$$;

-- Hapus akun (alur 7), dipanggil delete-account SETELAH core close_account sukses dan SEBELUM auth.admin.deleteUser.
-- Mengikuti constraint E-05/E-16:
--   KYC  · blocked → tombstone menyimpan nik_hash (NIK tidak bisa daftar ulang, FR-04);
--        · retain_until → tombstone menyimpan nik_enc + enc_key_version + legal_name (bukti potong PPh 21);
--        · keduanya → keduanya; tidak ada alasan retensi → baris dihapus (NIK boleh dipakai lagi).
--        Foto KTP (doc_ref) dan nik_last4 selalu dibuang; objek storage dihapus Edge Function.
--   Rekening · blocked → tombstone hanya account_no_hash (constraint payout_methods_tombstone_blocked);
--            · tidak blocked → baris dihapus.
-- E-28 consent, E-29 penerima, E-36 push, E-27 role ikut terhapus lewat ON DELETE CASCADE saat user Auth dihapus.
-- Idempoten: panggilan ulang tanpa baris tersisa hanya mencatat audit.
create function api.svc_close_member(p_user uuid, p_blocked boolean, p_retain_until date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  kyc_id uuid;
  kyc_result text := 'none';
  pm_deleted int := 0;
  pm_tombstoned int := 0;
begin
  if p_user is null or p_blocked is null then
    raise exception 'p_user dan p_blocked wajib' using errcode = '22023';
  end if;
  if p_retain_until is not null and p_retain_until <= current_date then
    raise exception 'retain_until harus setelah hari ini' using errcode = '22023';
  end if;

  select k.id into kyc_id from member.kyc_records k where k.user_id = p_user for update;
  if kyc_id is not null then
    if p_blocked or p_retain_until is not null then
      update member.kyc_records k
         set user_id = null,
             blocked = p_blocked,
             retain_until = p_retain_until,
             nik_hash = case when p_blocked then k.nik_hash end,
             nik_enc = case when p_retain_until is not null then k.nik_enc end,
             enc_key_version = case when p_retain_until is not null then k.enc_key_version end,
             legal_name = case when p_retain_until is not null then k.legal_name end,
             nik_last4 = null,
             doc_ref = null
       where k.id = kyc_id;
      kyc_result := 'tombstoned';
    else
      delete from member.kyc_records k where k.id = kyc_id;
      kyc_result := 'deleted';
      kyc_id := null;
    end if;
  end if;

  if p_blocked then
    update member.payout_methods pm
       set user_id = null, blocked = true, account_no_enc = null, account_last4 = null, account_name = null,
           enc_key_version = null
     where pm.user_id = p_user;
    get diagnostics pm_tombstoned = row_count;
  else
    delete from member.payout_methods pm where pm.user_id = p_user;
    get diagnostics pm_deleted = row_count;
  end if;

  insert into member.audit_logs (actor_id, action, target, after)
  values (p_user, 'account.close', 'user:' || p_user,
          jsonb_build_object('kyc_id', kyc_id, 'kyc', kyc_result, 'blocked', p_blocked, 'retain_until', p_retain_until,
                             'payout_methods_deleted', pm_deleted, 'payout_methods_tombstoned', pm_tombstoned));
  return jsonb_build_object('kyc', kyc_result, 'payout_methods_deleted', pm_deleted,
                            'payout_methods_tombstoned', pm_tombstoned);
end $$;

-- Jejak akses PII oleh Edge Function (export CSV, unggah bukti, unduh data sendiri, aksi Auth admin) ke E-24 identity.
-- Format action dijaga CHECK tabel (^[a-z_]+(\.[a-z_]+)+$).
create function api.svc_audit(p_actor uuid, p_action text, p_target text, p_after jsonb default null)
returns void
language sql security definer set search_path = '' as $$
  insert into member.audit_logs (actor_id, action, target, after) values (p_actor, p_action, p_target, p_after);
$$;

-- Unduh data saya (C2.4): semua baris identity milik user, ciphertext ikut (member-data yang mendekripsi).
create function api.svc_my_data(p_user uuid)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at)
                from auth.users u where u.id = p_user),
    'kyc', (select jsonb_build_object('legal_name', k.legal_name, 'nik_enc', k.nik_enc, 'enc_key_version', k.enc_key_version,
                                      'nik_last4', k.nik_last4, 'doc_ref', k.doc_ref, 'status', k.status,
                                      'reject_reason', k.reject_reason, 'submitted_at', k.submitted_at,
                                      'decided_at', k.decided_at)
            from member.kyc_records k where k.user_id = p_user),
    'payout_methods', coalesce((select jsonb_agg(jsonb_build_object('id', pm.id, 'kind', pm.kind, 'bank_code', pm.bank_code,
                                                                    'account_no_enc', pm.account_no_enc,
                                                                    'enc_key_version', pm.enc_key_version,
                                                                    'account_last4', pm.account_last4,
                                                                    'account_name', pm.account_name,
                                                                    'verified_at', pm.verified_at,
                                                                    'disabled_at', pm.disabled_at,
                                                                    'created_at', pm.created_at) order by pm.created_at)
                                from member.payout_methods pm where pm.user_id = p_user), '[]'::jsonb),
    'recipients', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reward_type_id', r.reward_type_id,
                                                                'data_enc', r.data_enc, 'enc_key_version', r.enc_key_version,
                                                                'updated_at', r.updated_at) order by r.updated_at)
                            from member.recipient_details r where r.user_id = p_user), '[]'::jsonb),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('kind', c.kind, 'version', c.version,
                                                              'granted_at', c.granted_at, 'revoked_at', c.revoked_at)
                                           order by c.granted_at)
                          from member.consents c where c.user_id = p_user), '[]'::jsonb),
    'push_subscriptions', coalesce((select jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'created_at', ps.created_at,
                                                                        'last_used_at', ps.last_used_at) order by ps.created_at)
                                    from member.push_subscriptions ps where ps.user_id = p_user), '[]'::jsonb),
    'platform_roles', coalesce((select jsonb_agg(pr.role order by pr.role)
                                from member.platform_roles pr where pr.user_id = p_user), '[]'::jsonb));
$$;

revoke execute on function api.svc_payout_methods(uuid[]) from public, anon, authenticated;
revoke execute on function api.svc_user_payout_methods(uuid) from public, anon, authenticated;
revoke execute on function api.svc_hash_holder(bytea, text, bytea) from public, anon, authenticated;
revoke execute on function api.svc_kyc(uuid[]) from public, anon, authenticated;
revoke execute on function api.svc_recipients(uuid[]) from public, anon, authenticated;
revoke execute on function api.svc_has_consent(uuid, text) from public, anon, authenticated;
revoke execute on function api.svc_platform_roles(uuid) from public, anon, authenticated;
revoke execute on function api.svc_admin_ids(text[]) from public, anon, authenticated;
revoke execute on function api.svc_push_subscriptions(uuid) from public, anon, authenticated;
revoke execute on function api.svc_delete_push(text) from public, anon, authenticated;
revoke execute on function api.svc_touch_push(text, text) from public, anon, authenticated;
revoke execute on function api.svc_check_ids(uuid[], uuid[], uuid[]) from public, anon, authenticated;
revoke execute on function api.svc_close_member(uuid, boolean, date) from public, anon, authenticated;
revoke execute on function api.svc_audit(uuid, text, text, jsonb) from public, anon, authenticated;
revoke execute on function api.svc_my_data(uuid) from public, anon, authenticated;
grant execute on function api.svc_payout_methods(uuid[]) to service_role;
grant execute on function api.svc_user_payout_methods(uuid) to service_role;
grant execute on function api.svc_hash_holder(bytea, text, bytea) to service_role;
grant execute on function api.svc_kyc(uuid[]) to service_role;
grant execute on function api.svc_recipients(uuid[]) to service_role;
grant execute on function api.svc_has_consent(uuid, text) to service_role;
grant execute on function api.svc_platform_roles(uuid) to service_role;
grant execute on function api.svc_admin_ids(text[]) to service_role;
grant execute on function api.svc_push_subscriptions(uuid) to service_role;
grant execute on function api.svc_delete_push(text) to service_role;
grant execute on function api.svc_touch_push(text, text) to service_role;
grant execute on function api.svc_check_ids(uuid[], uuid[], uuid[]) to service_role;
grant execute on function api.svc_close_member(uuid, boolean, date) to service_role;
grant execute on function api.svc_audit(uuid, text, text, jsonb) to service_role;
grant execute on function api.svc_my_data(uuid) to service_role;
