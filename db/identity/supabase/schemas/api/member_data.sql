-- Penyimpan data ber-PII, hanya untuk Edge Function member-data (secret key → role service_role).
-- Fungsi verifikasi JWT, cek umur dari NIK (≥ 18), hitung HMAC & enkripsi, lalu memanggil fungsi ini.
-- Browser tidak bisa memanggilnya, jadi hash palsu tidak bisa lolos UNIQUE (FR-04).

create function api.store_kyc(p_user_id uuid, p_nik_hash bytea, p_nik_enc bytea, p_nik_last4 text,
                              p_key_version smallint, p_legal_name text, p_doc_ref text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from member.kyc_records k where k.nik_hash = p_nik_hash and k.user_id is distinct from p_user_id) then
    raise exception 'NIK sudah dipakai akun lain' using errcode = '23505';
  end if;
  insert into member.kyc_records (user_id, nik_hash, nik_enc, nik_last4, enc_key_version, legal_name, doc_ref)
  values (p_user_id, p_nik_hash, p_nik_enc, p_nik_last4, p_key_version, p_legal_name, p_doc_ref)
  on conflict (user_id) do update
    set nik_hash = excluded.nik_hash, nik_enc = excluded.nik_enc, nik_last4 = excluded.nik_last4,
        enc_key_version = excluded.enc_key_version, legal_name = excluded.legal_name, doc_ref = excluded.doc_ref,
        status = 'pending', reject_reason = null, decided_at = null, decided_by = null, submitted_at = now()
    where member.kyc_records.status = 'rejected';
  if not found then
    raise exception 'KYC sudah dikirim dan belum ditolak' using errcode = '23505';
  end if;
  insert into member.audit_logs (actor_id, action, target) values (p_user_id, 'kyc.submit', 'user:' || p_user_id);
end $$;

create function api.store_payout_method(p_user_id uuid, p_kind text, p_bank_code text, p_account_no_hash bytea,
                                        p_account_no_enc bytea, p_last4 text, p_key_version smallint, p_account_name text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  kyc_name text;
  new_id uuid;
begin
  select k.legal_name into kyc_name from member.kyc_records k where k.user_id = p_user_id and k.status <> 'rejected';
  if kyc_name is null then
    raise exception 'lengkapi KYC dulu' using errcode = '22023';
  end if;
  if lower(regexp_replace(btrim(kyc_name), '\s+', ' ', 'g')) <> lower(regexp_replace(btrim(p_account_name), '\s+', ' ', 'g')) then
    raise exception 'nama pemilik rekening harus sama dengan nama KYC' using errcode = '22023';
  end if;
  insert into member.payout_methods (user_id, kind, bank_code, account_no_hash, account_no_enc, account_last4,
                                     account_name, enc_key_version)
  values (p_user_id, p_kind, p_bank_code, p_account_no_hash, p_account_no_enc, p_last4, p_account_name, p_key_version)
  returning id into new_id;
  insert into member.audit_logs (actor_id, action, target) values (p_user_id, 'payout_method.add', 'payout_method:' || new_id);
  return new_id;
end $$;

create function api.store_recipient(p_user_id uuid, p_reward_type_id uuid, p_data_enc bytea, p_key_version smallint)
returns uuid
language sql security definer set search_path = '' as $$
  insert into member.recipient_details (user_id, reward_type_id, data_enc, enc_key_version)
  values (p_user_id, p_reward_type_id, p_data_enc, p_key_version)
  on conflict (user_id, reward_type_id) do update
    set data_enc = excluded.data_enc, enc_key_version = excluded.enc_key_version, updated_at = now()
  returning id;
$$;

revoke execute on function api.store_kyc(uuid, bytea, bytea, text, smallint, text, text) from public;
revoke execute on function api.store_payout_method(uuid, text, text, bytea, bytea, text, smallint, text) from public;
revoke execute on function api.store_recipient(uuid, uuid, bytea, smallint) from public;
grant execute on function api.store_kyc(uuid, bytea, bytea, text, smallint, text, text) to service_role;
grant execute on function api.store_payout_method(uuid, text, text, bytea, bytea, text, smallint, text) to service_role;
grant execute on function api.store_recipient(uuid, uuid, bytea, smallint) to service_role;
