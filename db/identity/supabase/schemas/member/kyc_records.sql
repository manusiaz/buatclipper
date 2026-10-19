-- E-05 KYC, satu baris per user. NIK di-HMAC (UNIQUE, FR-04) dan dienkripsi di Edge Function member-data;
-- kuncinya secret fungsi, bukan isi database. Ditulis hanya lewat api.store_kyc (service role).
-- user_id NULL = tombstone setelah akun dihapus (alur 7): tersisa nik_hash kalau akun di-ban (blocked) supaya tidak bisa
-- daftar ulang, dan/atau nik_enc + legal_name untuk bukti potong PPh 21 sampai retain_until.
create table member.kyc_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users (id) on delete set null,
  nik_hash bytea check (octet_length(nik_hash) = 32),
  nik_enc bytea,
  nik_last4 text check (nik_last4 ~ '^[0-9]{4}$'),
  enc_key_version smallint check (enc_key_version > 0),
  legal_name text check (char_length(legal_name) between 2 and 100),
  doc_ref text,
  status member.kyc_status not null default 'pending',
  reject_reason text,
  submitted_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users (id) on delete set null,
  blocked boolean not null default false,
  retain_until date,
  constraint kyc_nik_unique unique (nik_hash),
  constraint kyc_active_complete check (user_id is null or (nik_hash is not null and nik_enc is not null
    and nik_last4 is not null and enc_key_version is not null and legal_name is not null and doc_ref is not null)),
  constraint kyc_tombstone_reason check (user_id is not null or blocked or retain_until is not null),
  constraint kyc_doc_in_own_folder check (user_id is null or doc_ref like user_id::text || '/%'),
  constraint kyc_decision_complete check ((status = 'pending') = (decided_at is null)),
  constraint kyc_reject_has_reason check (status <> 'rejected' or reject_reason is not null)
);
create index kyc_records_decided_by_idx on member.kyc_records (decided_by);
create index kyc_records_queue_idx on member.kyc_records (submitted_at) where status = 'pending' and user_id is not null;

alter table member.kyc_records enable row level security;
create policy kyc_own_read on member.kyc_records for select to authenticated using (user_id = (select auth.uid()));  -- policy:identity.rls-self
create policy kyc_hook on member.kyc_records for select to supabase_auth_admin using (true);  -- policy:identity.auth-hook
grant select (id, user_id, nik_last4, legal_name, status, reject_reason, submitted_at, decided_at)
  on member.kyc_records to authenticated;
grant select (user_id, status) on member.kyc_records to supabase_auth_admin;
