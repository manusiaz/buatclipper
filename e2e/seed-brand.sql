-- Seed E2E project brand: org E2E Studio + pemiliknya + campaign E2E (pasangan e2e/seed.sql di admin; id tetap, idempoten).
\set ON_ERROR_STOP 1
begin;
insert into market.profiles (id, username, display_name) values ('e2e00000-0000-0000-0000-0000000000b0', 'e2e_brand_owner', 'E2E Owner')
  on conflict do nothing;
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_by, verified_at, created_by)
values ('e2e00000-0000-0000-0000-0000000000a0', 'E2E Studio', 'badan', 'PT E2E Studio', '0123456789012777', 'Jakarta', 'verified',
        'e2e00000-0000-0000-0000-0000000000b0', now(), 'e2e00000-0000-0000-0000-0000000000b0') on conflict do nothing;
insert into market.org_members (org_id, user_id, role) values
  ('e2e00000-0000-0000-0000-0000000000a0', 'e2e00000-0000-0000-0000-0000000000b0', 'brand_owner') on conflict do nothing;
-- campaign E2E (isi milik brand; status/jadwal = replika admin, disamakan dengan e2e/seed.sql)
insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, required_hashtags, brief, review_mode, visibility,
                              created_by, status, start_at, submit_deadline)
values ('e2e00000-0000-0000-0000-0000000000c0', 'e2e00000-0000-0000-0000-0000000000a0', 'e2e-journey', 'E2E Journey Campaign',
        'clipping', 'games', '{tiktok}', '{e2eclipper}', '**Brief** E2E', 'manual', 'public', 'e2e00000-0000-0000-0000-0000000000b0',
        'live', now() - interval '1 day', now() + interval '14 days') on conflict do nothing;
commit;
