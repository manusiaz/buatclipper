-- test:rls.access-matrix (core) + invarian uang & state machine. Jalankan: supabase test db --workdir db/core
begin;
-- Fixture tes tidak bergantung seed.sql (supabase db reset memuatnya sebelum supabase test db); di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: semua tabel domain + antrean pgmq dikosongkan dulu.
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'tracking', 'finance', 'trust', 'ops')
     or (schemaname = 'pgmq' and tablename like 'q\_%')); end $$;
select no_plan();

-- ---------- data uji (sebagai postgres) ----------
insert into ops.settings (key, value) values
  ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"'),
  ('public.market.max_accounts_per_platform', '3'),
  ('public.finance.min_withdraw_idr', '100000');
insert into market.profiles (id, username, display_name) values
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi'),
  ('11111111-0000-0000-0000-00000000000b', 'budi', 'Budi'),
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1'),
  ('22222222-0000-0000-0000-0000000000b1', 'manager1', 'Manager 1'),
  ('22222222-0000-0000-0000-0000000000c1', 'finance1', 'Finance 1'),
  ('22222222-0000-0000-0000-0000000000a2', 'owner2', 'Owner 2');
insert into finance.fee_rules (id, scope) values ('f0000000-0000-0000-0000-000000000000', 'global');
insert into finance.fee_rules (id, scope, mgmt_fee_pct) values ('f0000000-0000-0000-0000-000000000001', 'org', 10);
insert into market.organizations (id, name, org_type, legal_name, npwp, address, fee_rule_id, status, verified_by, verified_at, created_by) values
  ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'badan', 'PT Studio Satu', '0123456789012345', 'Jakarta',
   'f0000000-0000-0000-0000-000000000001', 'verified', '33333333-0000-0000-0000-0000000000ad', now(), '33333333-0000-0000-0000-0000000000ad'),
  ('44444444-0000-0000-0000-000000000002', 'Toko Dua', 'perorangan', null, null, null, null, 'verified',
   '33333333-0000-0000-0000-0000000000ad', now(), '33333333-0000-0000-0000-0000000000ad');
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000b1', 'brand_manager'),
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000c1', 'brand_finance'),
  ('44444444-0000-0000-0000-000000000002', '22222222-0000-0000-0000-0000000000a2', 'brand_owner');
insert into market.categories (id, name_id, name_en) values ('games', 'Game', 'Games');
insert into market.reward_types (id, code, name, kind, unit_label, idr_value_per_unit, fulfillment) values
  ('77777777-0000-0000-0000-000000000001', 'IDR', 'Rupiah', 'cash', 'Rp', 1, 'payout');
insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, start_at, submit_deadline, created_by) values
  ('55555555-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000001', 'film-satu', 'Film Satu', 'clipping', 'games',
   '{tiktok}', now() - interval '1 day', now() + interval '14 days', '33333333-0000-0000-0000-0000000000ad'),
  ('55555555-0000-0000-0000-000000000002', '44444444-0000-0000-0000-000000000001', 'film-draft', 'Film Draft', 'clipping', 'games',
   '{tiktok}', null, null, '33333333-0000-0000-0000-0000000000ad');

-- ---------- struktur ----------
select is((select count(*)::int from pg_class c where c.relnamespace = 'api'::regnamespace and c.relkind = 'v'
            and not coalesce(c.reloptions @> array['security_invoker=true'], false)), 0, 'semua view api security_invoker');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'api'::regnamespace
            and has_function_privilege('anon', p.oid, 'execute')), array['invite_preview', 'list_campaigns', 'report_by_token'],
          'anon hanya bisa EXECUTE invite_preview, list_campaigns (landing) & report_by_token');
select is((select count(*)::int from pg_class c where c.relnamespace in ('market'::regnamespace, 'tracking'::regnamespace,
            'finance'::regnamespace, 'trust'::regnamespace, 'ops'::regnamespace) and c.relkind = 'r' and not c.relrowsecurity),
          0, 'RLS aktif di semua tabel core');
select is((select count(*)::int from pg_class c where c.relnamespace in ('market'::regnamespace, 'tracking'::regnamespace,
            'finance'::regnamespace, 'trust'::regnamespace, 'ops'::regnamespace) and c.relkind = 'r'
            and not exists (select 1 from pg_policy p where p.polrelid = c.oid and not p.polpermissive)),
          0, 'semua tabel core punya policy restrictive iss (JWT harus dari identity)');
select is((select count(*)::int from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
            where c.contype = 'f' and c.connamespace in ('market'::regnamespace, 'tracking'::regnamespace, 'finance'::regnamespace,
                                                     'trust'::regnamespace, 'ops'::regnamespace)
              and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1])),
          0, 'setiap foreign key punya index di kolom depannya');

-- ---------- state machine (trigger dari kg_v02.yaml) ----------
select throws_ok($$ update market.campaigns set status = 'live' where id = '55555555-0000-0000-0000-000000000001' $$,
                 '23514', null, 'S-01: draft → live langsung ditolak');
update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-000000000001';
update market.campaigns set status = 'scheduled' where id = '55555555-0000-0000-0000-000000000001';
select lives_ok($$ update market.campaigns set status = 'live' where id = '55555555-0000-0000-0000-000000000001' $$,
                'S-01: draft → in_review → scheduled → live');
select throws_ok($$ insert into market.campaigns (org_id, slug, title, type, platforms, status, created_by)
                    values ('44444444-0000-0000-0000-000000000001', 'x-live', 'Langsung live', 'ugc', '{tiktok}', 'live',
                            '33333333-0000-0000-0000-0000000000ad') $$, '23514', null, 'campaign baru wajib mulai dari draft');
insert into finance.reward_pools (id, campaign_id, reward_type_id, total, max_per_clip) values
  ('66666666-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', 1000000, 100000);
insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, params) values
  ('55555555-0000-0000-0000-000000000001', 'per_1k_views', '77777777-0000-0000-0000-000000000001',
   '66666666-0000-0000-0000-000000000001', '{"rate": 2000}');
select throws_ok($$ insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, params) values
                    ('55555555-0000-0000-0000-000000000002', 'per_1k_views', '77777777-0000-0000-0000-000000000001',
                     '66666666-0000-0000-0000-000000000001', '{"rate": 2000}') $$, '23503', null,
                 'rate rule tidak bisa memakai pool milik campaign lain');
select throws_ok($$ insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, params) values
                    ('55555555-0000-0000-0000-000000000001', 'milestone_bonus', '77777777-0000-0000-0000-000000000001',
                     '66666666-0000-0000-0000-000000000001', '{"amount": 50000}') $$, '23514', null,
                 'milestone_bonus tanpa threshold ditolak');

-- ---------- claim, akun sosmed, submisi ----------
insert into market.claims (id, campaign_id, user_id, expires_at) values
  ('88888888-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', now() + interval '48 hours');
select throws_ok($$ insert into market.claims (campaign_id, user_id, expires_at) values ('55555555-0000-0000-0000-000000000001',
                    '11111111-0000-0000-0000-00000000000a', now() + interval '48 hours') $$, '23505', null,
                 'F-C05: claim terbuka kedua di campaign yang sama ditolak');
insert into tracking.social_accounts (id, user_id, platform, external_id, handle) values
  ('99999999-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-1', '@andi'),
  ('99999999-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-2', '@andi2'),
  ('99999999-0000-0000-0000-000000000003', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-3', '@andi3');
select throws_ok($$ insert into tracking.social_accounts (user_id, platform, external_id, handle)
                    values ('11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-4', '@andi4') $$, '23514', null,
                 'akun TikTok ke-4 untuk clipper yang sama ditolak');
select throws_ok($$ insert into tracking.social_accounts (user_id, platform, external_id, handle)
                    values ('11111111-0000-0000-0000-00000000000b', 'tiktok', 'tt-1', '@curian') $$, '23505', null,
                 'akun sosmed yang sudah terhubung tidak bisa dipasang clipper lain');
select throws_ok($$ insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at)
                    values ('88888888-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000b',
                            '55555555-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', 'tiktok', 'v1',
                            'https://tiktok.com/@andi/video/1', now()) $$, '23503', null,
                 'submisi dengan user yang beda dari pemilik claim ditolak (FK komposit)');
insert into tracking.submissions (id, claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a',
   '55555555-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', 'tiktok', 'v1',
   'https://tiktok.com/@andi/video/1', now());
update market.claims set status = 'submitted' where id = '88888888-0000-0000-0000-000000000001';
select throws_ok($$ update market.claims set status = 'open' where id = '88888888-0000-0000-0000-000000000001' $$,
                 '23514', null, 'S-02: submitted → open ditolak');
update tracking.submissions set status = 'tracking', counted_views = 25000 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into market.claims (id, campaign_id, user_id, expires_at) values
  ('88888888-0000-0000-0000-000000000002', '55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', now() + interval '48 hours');
select throws_ok($$ insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at)
                    values ('88888888-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a',
                            '55555555-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', 'tiktok', 'v1',
                            'https://vm.tiktok.com/abc', now()) $$, '23505', null,
                 'video yang sama (platform + post_id) ke campaign yang sama ditolak walau URL beda');
insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message) values
  ('submission', 'aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'appeal', null, 'tolong cek lagi');
select throws_ok($$ insert into trust.review_decisions (target_type, target_id, actor_id, decision) values
                    ('submission', 'aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'appeal') $$,
                 '23505', null, 'banding kedua untuk submisi yang sama ditolak');
select throws_ok($$ update trust.review_decisions set message = 'diubah' $$, '42501', null, 'keputusan review append-only');

-- ---------- uang ----------
insert into finance.ledger_accounts (id, owner_type, owner_id, reward_type_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'campaign_pool', '66666666-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'user_wallet', '11111111-0000-0000-0000-00000000000b', '77777777-0000-0000-0000-000000000001');
insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id) values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', -50000, null, 'accrual', '1:r1'),
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000001', 50000, 'pending', 'accrual', '1:r1');
set constraints all immediate;
select pass('transaksi seimbang lolos cek saat commit');
select throws_ok($$ insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id)
                    values ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002',
                            '77777777-0000-0000-0000-000000000001', 1000, 'pending', 'adjustment', 'x') $$, '23514', null,
                 'transaksi tidak seimbang ditolak');
select throws_ok($$ insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id)
                    values ('cccccccc-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000002',
                            '77777777-0000-0000-0000-000000000001', 1000, null, 'adjustment', 'y') $$, '23514', null,
                 'entri user_wallet tanpa bucket state ditolak');
select throws_ok($$ insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id) values
                    ('cccccccc-0000-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', -50000, null, 'accrual', '1:r1'),
                    ('cccccccc-0000-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000001', 50000, 'pending', 'accrual', '1:r1') $$,
                 '23505', null, 'accrual yang sama (snapshot + rule) tidak bisa tercatat dua kali');
select throws_ok($$ update finance.ledger_entries set amount = 1 $$, '42501', null, 'ledger append-only');
set constraints all deferred;
select throws_ok($$ insert into finance.payout_batches (created_by, approved_by, status, cutoff_at) values
                    ('33333333-0000-0000-0000-0000000000ad', '33333333-0000-0000-0000-0000000000ad', 'approved', now()) $$,
                 '23514', null, 'pembuat batch tidak bisa menyetujui batchnya sendiri');
select throws_ok($$ insert into finance.invoices (number, org_id, subtotal, mgmt_fee, admin_fee, tax, total) values
                    ('INV-X', '44444444-0000-0000-0000-000000000001', 10000000, 1500000, 500000, 0, 11000000) $$,
                 '23514', null, 'total invoice yang tidak sama dengan subtotal + fee + pajak ditolak');
insert into finance.invoices (id, number, org_id, campaign_id, subtotal, mgmt_fee, admin_fee, tax, total, status, payment_channel,
                              payment_ref, paid_amount, paid_at, confirmed_by) values
  ('dddddddd-0000-0000-0000-000000000001', 'INV-1', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000001',
   10000000, 1500000, 500000, 0, 12000000, 'paid', 'transfer', 'REF-123', 12000000, now(), '33333333-0000-0000-0000-0000000000ad');
select throws_ok($$ insert into finance.invoices (number, org_id, campaign_id, subtotal, mgmt_fee, admin_fee, tax, total, status, payment_channel,
                    payment_ref, paid_amount, paid_at, confirmed_by) values ('INV-2', '44444444-0000-0000-0000-000000000002', '55555555-0000-0000-0000-000000000001', 100, 15, 5, 0, 120,
                    'paid', 'qris', 'REF-123', 120, now(), '33333333-0000-0000-0000-0000000000ad') $$, '23505', null,
                 'nomor referensi pembayaran yang sama ditolak');
select throws_ok($$ insert into market.organizations (name, org_type, npwp, created_by) values ('Budi Shop', 'perorangan', '3171012345670001',
                    '33333333-0000-0000-0000-0000000000ad') $$, '23514', null, 'org perorangan tidak boleh menyimpan NPWP/NIK di core');
select throws_ok($$ delete from market.org_members where user_id = '22222222-0000-0000-0000-0000000000a2' $$, '23514', null,
                 'brand_owner terakhir tidak bisa dihapus');

-- ---------- RLS per role ----------
set local role anon;
select is((select array_agg(slug::text) from api.campaigns), array['film-satu'], 'anon hanya melihat campaign yang tayang');
select is((select remaining from api.reward_pools), 1000000::numeric, 'anon melihat sisa budget campaign tayang');
select throws_ok($$ select * from api.claims $$, '42501', null, 'anon tidak bisa membaca claim');
select is((select array_agg(scope order by scope) from api.fee_rules), array['global'], 'anon hanya melihat fee rule global (harga publik)');
select throws_ok($$ select api.ensure_profile('anon', 'Anon') $$, '42501', null, 'anon tidak bisa memanggil ensure_profile');
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://evil.example/auth/v1"}';
select is((select count(*)::int from api.claims), 0, 'JWT dengan iss lain tidak melihat apa pun (policy restrictive)');
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.claims), 2, 'clipper A melihat 2 claim miliknya');
select is((select count(*)::int from api.campaigns), 1, 'clipper tidak melihat campaign draft');
select is((select amount from api.wallet_balances where state = 'pending'), 50000::numeric, 'clipper A melihat saldo pending miliknya');
select is((select count(*)::int from api.invoices), 0, 'clipper tidak melihat invoice brand');
select throws_ok($$ select token_ref from tracking.social_accounts $$, '42501', null, 'token_ref tidak bisa dibaca browser');
select throws_ok($$ select note from trust.review_decisions $$, '42501', null, 'catatan internal moderator tidak bisa dibaca browser');
select is((select count(*)::int from api.review_decisions), 1, 'clipper melihat banding miliknya');
select throws_ok($$ select api.ensure_profile('budi', 'Andi') $$, '23505', 'username_taken', 'username milik orang lain ditolak');
select is((select created from api.ensure_profile('andi_baru', 'Andi B')), false, 'ensure_profile memperbarui profil yang sudah ada');
select throws_ok($$ select api.ensure_profile('andi_baru', 'Andi B', null, '11111111-0000-0000-0000-00000000000b/a.webp') $$,
                 '22023', 'invalid:avatar_path', 'avatar di folder user lain ditolak');
select lives_ok($$ select api.ensure_profile('andi_baru', 'Andi B', null, '11111111-0000-0000-0000-00000000000a/a.webp') $$,
                'avatar milik sendiri diterima');
select lives_ok($$ select api.ensure_profile('andi_baru', 'Andi B') $$, 'update tanpa p_avatar_path');
select is((select avatar_path from api.profiles where id = '11111111-0000-0000-0000-00000000000a'),
          '11111111-0000-0000-0000-00000000000a/a.webp', 'avatar tersimpan & dipertahankan saat update tanpa avatar');
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.claims), 0, 'clipper B tidak melihat claim A');
select is((select count(*)::int from api.wallet_balances), 0, 'clipper B tidak melihat saldo A');

set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.campaigns), 2, 'brand_manager org1 melihat campaign draft org-nya');
select is((select count(*)::int from api.submissions), 1, 'brand_manager org1 melihat submisi campaign org-nya');
select is((select count(*)::int from api.invoices), 0, 'brand_manager tidak melihat invoice (tanpa billing)');
select is((select mgmt_fee_pct from api.fee_rules where scope = 'org'), 10.00::numeric, 'anggota org1 melihat fee negosiasi org-nya');
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000c1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.invoices), 1, 'brand_finance org1 melihat invoice org-nya');
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000a2","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.campaigns), 1, 'owner org2 tidak melihat draft org1');
select is((select count(*)::int from api.submissions), 0, 'owner org2 tidak melihat submisi org1');
select is((select count(*)::int from api.fee_rules where scope = 'org'), 0, 'fee negosiasi org1 tidak terlihat org2');
select throws_ok($$ select api.create_report_link('55555555-0000-0000-0000-000000000001') $$, '42501', null,
                 'org lain tidak bisa membuat link laporan');

set local request.jwt.claims = '{"sub":"33333333-0000-0000-0000-0000000000ad","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1","app_roles":["admin_finance"]}';
select is((select count(*)::int from api.payouts), 0, 'admin tanpa aal2 tidak melihat data admin');
select is((select count(*)::int from api.invoices), 0, 'admin tanpa aal2 tidak melihat invoice');
set local request.jwt.claims = '{"sub":"33333333-0000-0000-0000-0000000000ad","role":"authenticated","aal":"aal2","iss":"https://auth.contoh.id/auth/v1","app_roles":["admin_finance"]}';
select is((select count(*)::int from api.invoices), 1, 'admin_finance aal2 melihat semua invoice');
select is((select count(*)::int from api.campaigns), 2, 'admin aal2 melihat semua campaign');
select is((select count(*)::int from api.audit_logs), 0, 'audit log hanya untuk admin_super');
reset role;

-- ---------- link laporan read-only (F-B09) ----------
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000a1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
create temp table t_tok on commit drop as select api.create_report_link('55555555-0000-0000-0000-000000000001') as tok;
reset role;
grant select on t_tok to anon;
set local role anon;
select is((select (api.report_by_token((select tok from t_tok)) ->> 'views_valid')::bigint), 25000::bigint,
          'anon dengan token melihat views valid campaign');
select is(api.report_by_token('token-palsu'), null, 'token salah tidak membuka apa pun');
reset role;
update market.report_links set revoked_at = now();
set local role anon;
select is(api.report_by_token((select tok from t_tok)), null, 'link yang dicabut tidak bisa dibuka lagi');
reset role;

-- ---------- storage core ----------
insert into storage.buckets (id, name, public) values ('campaign-covers', 'campaign-covers', true), ('avatars', 'avatars', true) on conflict (id) do nothing;
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('campaign-covers',
                   '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000001/cover.webp') $$,
                'brand_manager unggah cover ke folder org-nya');
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000a2","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('campaign-covers',
                    '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000001/x.webp') $$, '42501', null,
                 'org lain tidak bisa unggah ke folder org1');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '22222222-0000-0000-0000-0000000000a2/a.webp') $$,
                'user unggah avatar ke foldernya');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '11111111-0000-0000-0000-00000000000a/a.webp') $$,
                 '42501', null, 'user tidak bisa unggah avatar ke folder orang lain');
reset role;

-- ---------- notifikasi & job ----------
insert into ops.notification_prefs (user_id, email_promotions) values ('11111111-0000-0000-0000-00000000000a', false);
select ops.enqueue_notification('11111111-0000-0000-0000-00000000000a', 'campaign.new', '{}');
select ops.enqueue_notification('11111111-0000-0000-0000-00000000000a', 'payout.paid', '{}');
select is((select array_agg(message ->> 'event') from pgmq.q_email), array['payout.paid'],
          'email promosi dilewati kalau dimatikan; email transaksional tetap dikirim');
insert into market.claims (id, campaign_id, user_id, expires_at, created_at) values
  ('88888888-0000-0000-0000-000000000003', '55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000b',
   now() + interval '2 hours', now() - interval '46 hours');
select market.run_claim_expiry();
select is((select count(*)::int from ops.notifications where event = 'claim.expiring'), 1, 'pengingat claim mau habis terkirim');
update market.claims set expires_at = now() - interval '1 minute', created_at = now() - interval '49 hours'
 where id = '88888888-0000-0000-0000-000000000003';
select market.run_claim_expiry();
select is((select status::text from market.claims where id = '88888888-0000-0000-0000-000000000003'), 'expired',
          'claim lewat 48 jam jadi expired');
select is((select count(*)::int from cron.job), 14, '14 job pg_cron core terdaftar');
select is(array(select distinct m[1] from cron.job, regexp_matches(command, '([a-z_]+\.[a-z_]+)\(', 'g') m
                where to_regproc(m[1]) is null order by 1),
          '{}'::text[], 'semua fungsi yang dipanggil job pg_cron sudah ada');

-- Regresi 2026-10-19: enum internal di parameter RPC → 42501 lewat REST walau pgTAP (literal) lulus.
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api' and exists (select 1 from unnest(p.proargtypes) t join pg_type ty on ty.oid = t
              join pg_namespace tn on tn.oid = ty.typnamespace where tn.nspname not in ('pg_catalog', 'api', 'extensions'))),
          null, 'argumen fungsi api tidak bertipe schema internal (PostgREST meng-cast argumen; role API tanpa USAGE schema itu)');
select * from finish();
rollback;
