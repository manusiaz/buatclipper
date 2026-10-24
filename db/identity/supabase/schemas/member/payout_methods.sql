-- E-16 rekening. Nomor rekening di-HMAC (UNIQUE bank + hash, FR-04) dan dienkripsi di Edge Function member-data.
-- Ditulis hanya lewat api.store_payout_method (service role), yang mewajibkan nama rekening = nama KYC.
-- user_id NULL = tombstone akun ter-ban: hanya hash yang tersisa.
create table member.payout_methods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  kind text not null check (kind in ('bank', 'ewallet')),
  bank_code text not null check (bank_code ~ '^[A-Z0-9_]{2,20}$'),
  account_no_hash bytea not null check (octet_length(account_no_hash) = 32),
  account_no_enc bytea,
  account_last4 text check (account_last4 ~ '^[0-9]{4}$'),
  account_name text check (char_length(account_name) between 2 and 100),
  enc_key_version smallint check (enc_key_version > 0),
  verified_at timestamptz,
  disabled_at timestamptz,
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  constraint payout_methods_account_unique unique (bank_code, account_no_hash),
  constraint payout_methods_active_complete check (user_id is null or (account_no_enc is not null
    and account_last4 is not null and account_name is not null and enc_key_version is not null)),
  constraint payout_methods_tombstone_blocked check (user_id is not null or blocked)
);
create index payout_methods_user_idx on member.payout_methods (user_id);

alter table member.payout_methods enable row level security;
create policy payout_methods_own_read on member.payout_methods for select to authenticated using (user_id = (select auth.uid()));  -- policy:identity.rls-self
grant select (id, user_id, kind, bank_code, account_last4, account_name, verified_at, disabled_at, created_at)
  on member.payout_methods to authenticated;
