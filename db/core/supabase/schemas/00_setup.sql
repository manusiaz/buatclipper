-- Project core: campaign, tracking, uang. Tanpa PII. Data API hanya mengekspos schema api.
create schema if not exists market;
create schema if not exists tracking;
create schema if not exists finance;
create schema if not exists trust;
create schema if not exists ops;
create schema if not exists api;

grant usage on schema api to anon, authenticated, service_role;

-- EXECUTE fungsi baru diberikan ke PUBLIC secara global; REVOKE per schema tidak bisa mencabutnya, jadi dicabut global.
alter default privileges for role postgres revoke execute on functions from public;

create type market.platform as enum ('tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x');
create type market.org_role as enum ('brand_owner', 'brand_manager', 'brand_finance', 'brand_viewer');
create type market.org_status as enum ('pending_verification', 'verified', 'suspended');
create type market.profile_status as enum ('active', 'suspended', 'banned', 'closed');

-- Dipakai tabel append-only (ledger, snapshot, keputusan review, audit log).
create function ops.reject_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $$;
