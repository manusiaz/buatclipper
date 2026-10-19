-- Project identity: login (Supabase Auth) + data ber-PII. Data API hanya mengekspos schema api.
create schema if not exists member;
create schema if not exists api;

grant usage on schema api to anon, authenticated, service_role;
grant usage on schema member to supabase_auth_admin;

-- EXECUTE fungsi baru diberikan ke PUBLIC secara global. REVOKE per schema tidak bisa mencabut hak global itu
-- (dokumentasi ALTER DEFAULT PRIVILEGES), jadi dicabut global untuk role pembuat objek; tiap fungsi di-grant eksplisit.
alter default privileges for role postgres revoke execute on functions from public;

create type member.platform_role as enum ('admin_super', 'admin_ops', 'admin_moderator', 'admin_finance', 'admin_support');
create type member.consent_kind as enum ('tos_clipper', 'tos_brand', 'privacy', 'age_18_plus', 'kyc', 'share_with_brand');
create type member.kyc_status as enum ('pending', 'approved', 'rejected');

-- Dipakai tabel append-only (audit log).
create function member.reject_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $$;
