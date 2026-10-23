-- Seed E2E project creator: profil pemilik E2E Studio (pasangan e2e/seed.sql & seed-brand.sql; id tetap, idempoten).
\set ON_ERROR_STOP 1
insert into market.profiles (id, username, display_name) values ('e2e00000-0000-0000-0000-0000000000b0', 'e2e_brand_owner', 'E2E Owner')
  on conflict do nothing;
