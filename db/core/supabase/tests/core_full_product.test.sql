-- Fitur produk penuh: campaign privat & template, agency, referral, leaderboard, kode voucher, invoice
-- top-up/pinned/managed, instant withdraw, riwayat Trust Score, brief terstruktur & berkas internal brand. Jalankan: supabase test db --workdir db/core
begin;
-- Fixture tes tidak bergantung seed.sql (supabase db reset memuatnya sebelum supabase test db); di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: semua tabel domain + antrean pgmq dikosongkan dulu.
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'tracking', 'finance', 'trust', 'ops')
     or (schemaname = 'pgmq' and tablename like 'q\_%')); end $$;
select no_plan();

insert into ops.settings (key, value) values ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"');
insert into market.profiles (id, username, display_name, trust_score) values
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi', 80),
  ('11111111-0000-0000-0000-00000000000b', 'budi', 'Budi', 40),
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1', 50),
  ('22222222-0000-0000-0000-0000000000e1', 'agency1', 'Agency 1', 50);
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_by, verified_at, created_by, is_agency) values
  ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'badan', 'PT Studio Satu', '0123456789012345', 'Jakarta', 'verified',
   '33333333-0000-0000-0000-0000000000ad', now(), '33333333-0000-0000-0000-0000000000ad', false),
  ('44444444-0000-0000-0000-0000000000a9', 'Agensi Kreatif', 'badan', 'PT Agensi Kreatif', '0123456789012399', 'Bandung', 'verified',
   '33333333-0000-0000-0000-0000000000ad', now(), '33333333-0000-0000-0000-0000000000ad', true);
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-0000000000a9', '22222222-0000-0000-0000-0000000000e1', 'brand_manager');
insert into market.reward_types (id, code, name, kind, unit_label, idr_value_per_unit, fulfillment) values
  ('77777777-0000-0000-0000-000000000001', 'IDR', 'Rupiah', 'cash', 'Rp', 1, 'payout'),
  ('77777777-0000-0000-0000-000000000002', 'VOUCHER50', 'Voucher 50rb', 'voucher_code', 'voucher', 50000, 'code_pool');
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by, visibility, min_trust_score) values
  ('55555555-0000-0000-0000-000000000011', '44444444-0000-0000-0000-000000000001', 'undangan', 'Khusus undangan', 'clipping',
   '{tiktok}', now() - interval '1 day', now() + interval '7 days', '33333333-0000-0000-0000-0000000000ad', 'invite', 0),
  ('55555555-0000-0000-0000-000000000012', '44444444-0000-0000-0000-000000000001', 'level-70', 'Trust 70+', 'clipping',
   '{tiktok}', now() - interval '1 day', now() + interval '7 days', '33333333-0000-0000-0000-0000000000ad', 'level', 70);
update market.campaigns set status = 'in_review' where org_id = '44444444-0000-0000-0000-000000000001';
update market.campaigns set status = 'scheduled' where org_id = '44444444-0000-0000-0000-000000000001';
update market.campaigns set status = 'live' where org_id = '44444444-0000-0000-0000-000000000001';
insert into market.campaign_invites (campaign_id, user_id, invited_by) values
  ('55555555-0000-0000-0000-000000000011', '11111111-0000-0000-0000-00000000000a', '22222222-0000-0000-0000-0000000000a1');
insert into market.campaigns (id, org_id, slug, title, type, platforms, created_by, is_template) values
  ('55555555-0000-0000-0000-000000000013', '44444444-0000-0000-0000-000000000001', 'template-1', 'Template film', 'clipping',
   '{tiktok}', '22222222-0000-0000-0000-0000000000a1', true);

-- Campaign privat (F-B11) & template (F-B10)
select throws_ok($$ update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-000000000013' $$,
                 '23514', null, 'template tidak bisa diajukan tayang');
set local role anon;
select is((select count(*)::int from api.campaigns), 0, 'anon tidak melihat campaign privat');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select array_agg(slug::text order by slug) from api.campaigns), array['level-70', 'undangan'],
          'Andi (diundang, trust 80) melihat dua campaign privat');
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.campaigns), 0, 'Budi (tidak diundang, trust 40) tidak melihat keduanya');

-- Agency (F-B12): sebelum ditautkan tidak melihat apa-apa; setelah disetujui melihat draft klien; setelah dicabut hilang lagi.
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000e1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.campaigns where is_template), 0, 'agency belum tertaut tidak melihat template klien');
reset role;
insert into market.org_links (agency_org_id, client_org_id) values
  ('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from api.campaigns where is_template), 0, 'tautan belum disetujui brand_owner klien → belum ada akses');
reset role;
update market.org_links set approved_by = '22222222-0000-0000-0000-0000000000a1', approved_at = now();
set local role authenticated;
select is((select count(*)::int from api.campaigns where is_template), 1, 'agency tertaut melihat template klien');
select is((select role::text from api.org_members where org_id = '44444444-0000-0000-0000-0000000000a9'), 'brand_manager',
          'agency tetap melihat keanggotaannya sendiri');
reset role;
update market.org_links set revoked_at = now();
set local role authenticated;
select is((select count(*)::int from api.campaigns where is_template), 0, 'tautan dicabut → akses klien hilang');
reset role;

-- Referral (F-C16)
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
create temp table t_ref on commit drop as select api.my_referral_code() as code;
reset role;
grant select on t_ref to authenticated;
select ok((select code ~ '^[a-z0-9]{8}$' from t_ref), 'kode referral 8 karakter dibuat saat diminta');
set local role authenticated;
reset role;
-- Profil baru di creator: replika tiba di admin, lalu event referral.record (kode tak dikenal / milik sendiri diabaikan).
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-0000000000cc', 'citra', 'Citra');
select lives_ok($$ select bus_in.referral_record(jsonb_build_object('user_id', '11111111-0000-0000-0000-0000000000cc', 'code', 'zzzzzzzz')) $$,
                'kode referral tidak dikenal diabaikan tanpa error');
select lives_ok($$ select bus_in.referral_record(jsonb_build_object('user_id', '11111111-0000-0000-0000-00000000000a', 'code', (select code from t_ref))) $$,
                'kode referral milik sendiri diabaikan tanpa error');
select is((select count(*)::int from market.referrals where referred_id in ('11111111-0000-0000-0000-0000000000cc', '11111111-0000-0000-0000-00000000000a')),
          0, 'referral tidak dicatat dari kode tak dikenal / milik sendiri');
select bus_in.referral_record(jsonb_build_object('user_id', '11111111-0000-0000-0000-0000000000cc', 'code', (select code from t_ref)));
select bus_in.referral_record(jsonb_build_object('user_id', '11111111-0000-0000-0000-0000000000cc', 'code', (select code from t_ref)));
select is((select count(*)::int from market.referrals where referred_id = '11111111-0000-0000-0000-0000000000cc'), 1,
          'profil baru dari link referral (event ulang idempoten)');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select referred_username from api.referrals), 'citra', 'pengundang melihat teman yang mendaftar');
reset role;
select throws_ok($$ insert into market.referrals (referred_id, referrer_id, code) values ('11111111-0000-0000-0000-00000000000b',
                    '11111111-0000-0000-0000-00000000000b', 'x') $$, '23514', null, 'referral ke diri sendiri ditolak');

-- Leaderboard (F-C13): baris campaign privat tidak terlihat oleh yang tidak berhak
insert into market.claims (id, campaign_id, user_id, expires_at) values
  ('88888888-0000-0000-0000-000000000011', '55555555-0000-0000-0000-000000000011', '11111111-0000-0000-0000-00000000000a', now() + interval '48 hours');
insert into tracking.social_accounts (id, user_id, platform, external_id, handle) values
  ('99999999-0000-0000-0000-000000000011', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-11', '@andi');
insert into tracking.submissions (id, claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at) values
  ('aaaaaaaa-0000-0000-0000-000000000011', '88888888-0000-0000-0000-000000000011', '11111111-0000-0000-0000-00000000000a',
   '55555555-0000-0000-0000-000000000011', '99999999-0000-0000-0000-000000000011', 'tiktok', 'v11', 'https://tiktok.com/@andi/video/11', now());
update tracking.submissions set status = 'tracking', counted_views = 12000 where id = 'aaaaaaaa-0000-0000-0000-000000000011';
select market.refresh_leaderboard();
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select views from api.leaderboard where scope = 'campaign'), 12000::bigint, 'Andi melihat leaderboard campaign undangannya');
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.leaderboard where scope = 'campaign'), 0, 'Budi tidak melihat leaderboard campaign privat');
select is((select username from api.leaderboard where scope = 'week'), 'andi', 'leaderboard mingguan global terlihat semua clipper');
reset role;

-- Kode voucher (F-B03 code_pool): hanya pemilik fulfillment yang melihat kodenya
insert into finance.fulfillments (id, user_id, reward_type_id, amount, idempotency_key) values
  ('eeeeeeee-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000002', 1, 'f-1');
insert into finance.reward_codes (reward_type_id, code, fulfillment_id, uploaded_by, assigned_at) values
  ('77777777-0000-0000-0000-000000000002', 'VCR-AAA', 'eeeeeeee-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', now()),
  ('77777777-0000-0000-0000-000000000002', 'VCR-BBB', null, '22222222-0000-0000-0000-0000000000a1', null);
select throws_ok($$ insert into finance.reward_codes (reward_type_id, code, uploaded_by) values
                    ('77777777-0000-0000-0000-000000000002', 'VCR-AAA', '22222222-0000-0000-0000-0000000000a1') $$, '23505', null,
                 'kode voucher duplikat ditolak');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select array_agg(code) from api.reward_codes), array['VCR-AAA'], 'clipper hanya melihat kode miliknya');
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.reward_codes), 0, 'clipper lain tidak melihat kode');
reset role;

-- Invoice top-up/pinned/managed & instant withdraw
select throws_ok($$ insert into finance.invoices (number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, total)
                    values ('INV-P', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000011', 'pinned', 0, 0, 0,
                            500000, 500000) $$, '23514', null, 'invoice pinned tanpa periode ditolak');
select lives_ok($$ insert into finance.invoices (number, org_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, total)
                   values ('INV-M', '44444444-0000-0000-0000-000000000001', 'managed_service', 0, 0, 0, 3000000, 3000000) $$,
                'invoice paket managed (REV-3) tanpa campaign diterima');
insert into finance.payout_batches (id, created_by, cutoff_at) values ('bbbbbbbb-0000-0000-0000-0000000000b1', '33333333-0000-0000-0000-0000000000ad', now());
select throws_ok($$ insert into finance.payouts (user_id, method_id, batch_id, channel, amount, idempotency_key) values
                    ('11111111-0000-0000-0000-00000000000a', gen_random_uuid(), 'bbbbbbbb-0000-0000-0000-0000000000b1', 'instant', 150000, 'p-1') $$,
                 '23514', null, 'instant withdraw tidak masuk batch');

-- Trust Score (F-C12): riwayat append-only, override admin wajib punya pelaku
select throws_ok($$ insert into trust.score_events (user_id, delta, reason) values ('11111111-0000-0000-0000-00000000000a', 5, 'admin_override') $$,
                 '23514', null, 'override Trust Score tanpa admin pelaku ditolak');
insert into trust.score_events (user_id, delta, reason, ref_id) values ('11111111-0000-0000-0000-00000000000a', 2, 'submission_approved', 'x');
select throws_ok($$ delete from trust.score_events $$, '42501', null, 'riwayat Trust Score append-only');

-- Brief terstruktur (F-B02, F-C04, F-C06): format, cek caption otomatis, kunci setelah diajukan, berkas internal brand
select throws_ok($$ insert into market.campaigns (org_id, slug, title, type, platforms, created_by, required_hashtags)
                    values ('44444444-0000-0000-0000-000000000001', 'tag-salah', 'Tag salah', 'clipping', '{tiktok}',
                            '22222222-0000-0000-0000-0000000000a1', '{#MPLID}') $$,
                 '23514', null, 'hashtag wajib disimpan huruf kecil tanpa #');
select throws_ok($$ insert into market.campaigns (org_id, slug, title, type, platforms, created_by, min_duration_sec, max_duration_sec)
                    values ('44444444-0000-0000-0000-000000000001', 'durasi-salah', 'Durasi salah', 'clipping', '{tiktok}',
                            '22222222-0000-0000-0000-0000000000a1', 90, 30) $$,
                 '23514', null, 'durasi minimum tidak boleh melebihi maksimum');
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by, brief,
                              required_hashtags, required_mentions, required_links, min_duration_sec, max_duration_sec, dos, donts) values
  ('55555555-0000-0000-0000-000000000014', '44444444-0000-0000-0000-000000000001', 'brief-lengkap', 'Brief lengkap', 'clipping',
   '{tiktok,instagram}', now() - interval '1 day', now() + interval '7 days', '22222222-0000-0000-0000-0000000000a1',
   'Potong adegan terbaik film.', '{mplid,clipper}', '{studiosatu}', '{https://studio.id/promo}', 15, 60,
   '{Pakai subtitle}', '{Jangan pakai musik berhak cipta}');
update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-000000000014';
update market.campaigns set status = 'scheduled' where id = '55555555-0000-0000-0000-000000000014';
update market.campaigns set status = 'live' where id = '55555555-0000-0000-0000-000000000014';
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is(api.missing_brief_tags('55555555-0000-0000-0000-000000000014', 'Seru! #MPLID #Clipper @StudioSatu. Info: studio.id/promo'),
          '{}'::text[], 'caption lengkap: tidak ada yang kurang (huruf besar/kecil diabaikan)');
select is(api.missing_brief_tags('55555555-0000-0000-0000-000000000014', 'cuma #mplid'),
          array['#clipper', '@studiosatu', 'https://studio.id/promo'], 'yang kurang disebut satu per satu');
select is(api.missing_brief_tags('55555555-0000-0000-0000-000000000013', '#film'), null, 'campaign yang tidak terlihat: NULL');
reset role;
-- Brief dikunci di project brand dari replika status yang bisa tertinggal (admin → brand macet); isi baru yang tetap tiba setelah
-- disetujui dibekukan di admin (R95-1): isi lama dipertahankan + alert, event tidak ditolak.
update market.campaigns set submitted_version = content_version where id = '55555555-0000-0000-0000-000000000014';
create temp table t_r95 as select required_hashtags h, content_version v from market.campaigns where id = '55555555-0000-0000-0000-000000000014';
select lives_ok($$ select api.bus_receive('brand', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row',
                   'payload', jsonb_build_object('table', 'market.campaigns', 'op', 'upsert', 'key', '{"id":"55555555-0000-0000-0000-000000000014"}'::jsonb,
                   'row', jsonb_build_object('id', '55555555-0000-0000-0000-000000000014', 'required_hashtags', array['baru'],
                     'content_version', (select content_version + 1 from market.campaigns where id = '55555555-0000-0000-0000-000000000014')))))) $$,
                'replika isi tiba walau campaign tayang (antrean bus tidak macet)');
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-000000000014'), 'live', 'status tetap');
select ok((select required_hashtags = (select h from t_r95) and content_version = (select v from t_r95) from market.campaigns
            where id = '55555555-0000-0000-0000-000000000014'), 'R95-1: isi yang disetujui tidak berubah lewat replika (tag wajib & versi tetap)');
select ok(exists (select 1 from ops.alerts where kind = 'campaign.content_drift' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000014'),
          'R95-1: isi baru setelah disetujui → alert untuk admin');
select lives_ok($$ update market.campaigns set faq = '[{"q":"Boleh pakai musik?","a":"Yang bebas lisensi"}]'
                   where id = '55555555-0000-0000-0000-000000000014' $$, 'FAQ tetap bisa ditambah saat tayang');
select lives_ok($$ update market.campaigns set required_hashtags = '{film}' where id = '55555555-0000-0000-0000-000000000013' $$,
                'draft (termasuk template) bebas diubah');
select throws_ok($$ insert into market.campaign_assets (campaign_id, kind, storage_path, audience) values
                    ('55555555-0000-0000-0000-000000000014', 'document',
                     '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000014/brief.pdf', 'internal') $$,
                 '23514', null, 'berkas internal wajib di folder internal/');
insert into market.campaign_assets (campaign_id, kind, storage_path, audience) values
  ('55555555-0000-0000-0000-000000000014', 'video',
   '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000014/aset.mp4', 'clipper'),
  ('55555555-0000-0000-0000-000000000014', 'document',
   '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000014/internal/brief-brand.pdf', 'internal');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select array_agg(audience) from api.campaign_assets where campaign_id = '55555555-0000-0000-0000-000000000014'),
          array['clipper'], 'clipper hanya melihat aset brief, bukan berkas internal brand');
set local request.jwt.claims = '{"sub":"22222222-0000-0000-0000-0000000000a1","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select is((select count(*)::int from api.campaign_assets where campaign_id = '55555555-0000-0000-0000-000000000014'), 2,
          'anggota org melihat aset brief + berkas internal');
reset role;

select * from finish();
rollback;
