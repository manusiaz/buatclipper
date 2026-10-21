-- test:identity.svc — fungsi service role untuk Edge Function identity (api/svc.sql). Jalankan: supabase test db --workdir db/identity
begin;
-- Fixture tes tidak bergantung seed.sql (supabase db reset memuatnya sebelum supabase test db); di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: tabel member + objek bucket identity dikosongkan dulu (di-rollback).
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname = 'member'); end $$;
set local storage.allow_delete_query = 'true';
delete from storage.objects where bucket_id in ('kyc-docs', 'pii-exports', 'payout-proofs');
reset storage.allow_delete_query;
select no_plan();

insert into auth.users (id, email, banned_until) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@contoh.id', now() + interval '100 years'),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@contoh.id', null),
  ('00000000-0000-0000-0000-0000000000c1', 'c1@contoh.id', null),
  ('00000000-0000-0000-0000-0000000000d1', 'd1@contoh.id', null),
  ('00000000-0000-0000-0000-0000000000e1', 'e1@contoh.id', null),
  ('00000000-0000-0000-0000-0000000000f1', 'f1@contoh.id', null);
insert into member.platform_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000f1', 'admin_moderator'),
  ('00000000-0000-0000-0000-0000000000f1', 'admin_finance');
insert into member.legal_versions (kind, version, published_at, url) values
  ('privacy', '2026-09-01', now() - interval '40 days', 'https://contoh.id/legal/privacy'),
  ('privacy', '2026-10-01', now() - interval '1 day', 'https://contoh.id/legal/privacy');

-- Hak akses: semua svc_* hanya untuk service_role, security definer, search_path kosong.
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname like 'svc\_%'), 20,
          '20 fungsi svc_* ada');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname like 'svc\_%'
            and has_function_privilege('authenticated', p.oid, 'execute')), 0, 'authenticated tidak bisa EXECUTE svc_*');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname like 'svc\_%'
            and has_function_privilege('anon', p.oid, 'execute')), 0, 'anon tidak bisa EXECUTE svc_*');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname like 'svc\_%'
            and not has_function_privilege('service_role', p.oid, 'execute')), 0, 'service_role bisa EXECUTE semua svc_*');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname like 'svc\_%'
            and not (p.prosecdef and p.proconfig @> array['search_path=""'])), 0,
          'semua svc_* security definer + search_path kosong');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal2"}';
select throws_ok($$ select api.svc_my_data('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
                 'browser tidak bisa membaca data PII user lain lewat svc_my_data');
select throws_ok($$ select api.svc_close_member('00000000-0000-0000-0000-0000000000a1', false, null) $$, '42501', null,
                 'browser tidak bisa menutup akun lewat svc_close_member');
reset role;
set local role anon;
select throws_ok($$ select * from api.svc_payout_methods(array['00000000-0000-0000-0000-000000000001'::uuid]) $$, '42501', null,
                 'anon tidak bisa membaca ciphertext rekening');
select throws_ok($$ select * from api.svc_user_payout_methods('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
                 'anon tidak bisa membaca rekening user lewat svc_user_payout_methods');
reset role;

-- Fixture PII lewat penyimpan service role (seperti member-data).
set local role service_role;
select api.store_kyc('00000000-0000-0000-0000-0000000000a1', sha256('NIK-A'::bytea), '\x0a01', '0001', 1::smallint,
                     'Andi Saputra', '00000000-0000-0000-0000-0000000000a1/ktp.jpg');
select api.store_kyc('00000000-0000-0000-0000-0000000000b1', sha256('NIK-B'::bytea), '\x0b01', '0002', 2::smallint,
                     'Budi Santoso', '00000000-0000-0000-0000-0000000000b1/ktp.jpg');
select api.store_kyc('00000000-0000-0000-0000-0000000000e1', sha256('NIK-E'::bytea), '\x0e01', '0005', 1::smallint,
                     'Eka Putri', '00000000-0000-0000-0000-0000000000e1/ktp.jpg');
reset role;
update member.kyc_records set status = 'approved', decided_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1');
set local role service_role;
create temp table t_pm (k text primary key, id uuid) on commit drop;
insert into t_pm values
  ('a', api.store_payout_method('00000000-0000-0000-0000-0000000000a1', 'bank', 'BCA', sha256('ACC-A'::bytea), '\x0a02', '4567', 1::smallint, 'Andi Saputra')),
  ('b', api.store_payout_method('00000000-0000-0000-0000-0000000000b1', 'ewallet', 'OVO', sha256('ACC-B'::bytea), '\x0b02', '8888', 1::smallint, 'budi  santoso'));
create temp table t_rcp (k text primary key, id uuid) on commit drop;
insert into t_rcp values
  ('b', api.store_recipient('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000ff', '\x0b03', 1::smallint));

-- Baca untuk CSV payout / disburse / export penerima.
select is((select row(user_id, bank_code, account_no_enc, enc_key_version, account_name, disabled_at, blocked)::text
           from api.svc_payout_methods(array[(select id from t_pm where k = 'a')])),
          row('00000000-0000-0000-0000-0000000000a1'::uuid, 'BCA', '\x0a02'::bytea, 1::smallint, 'Andi Saputra',
              null::timestamptz, false)::text,
          'svc_payout_methods: pemilik, bank, ciphertext, versi kunci, nama, disabled, blocked');
select is((select count(*)::int from api.svc_payout_methods(array[(select id from t_pm where k = 'a'),
                                                                 '00000000-0000-0000-0000-000000000099'::uuid])), 1,
          'svc_payout_methods: ID tidak dikenal diabaikan');
select is((select array_agg(bank_code) from api.svc_user_payout_methods('00000000-0000-0000-0000-0000000000a1')), array['BCA'],
          'svc_user_payout_methods (AB-6 refund perorangan): rekening bank aktif milik user itu saja');
select is((select count(*)::int from api.svc_user_payout_methods('00000000-0000-0000-0000-0000000000b1')), 0,
          'svc_user_payout_methods: e-wallet tidak dipakai untuk refund');
select is((select user_id from api.svc_hash_holder(sha256('NIK-B'::bytea), null, null)), '00000000-0000-0000-0000-0000000000b1'::uuid,
          'svc_hash_holder (FR-04): pemegang NIK yang dicoba dipakai ulang');
select is((select user_id from api.svc_hash_holder(null, 'BCA', sha256('ACC-A'::bytea))), '00000000-0000-0000-0000-0000000000a1'::uuid,
          'svc_hash_holder: pemegang rekening (bank + hash)');
select is((select count(*)::int from api.svc_hash_holder(null, 'BRI', sha256('ACC-A'::bytea))), 0, 'svc_hash_holder: bank lain = bukan pemegang');
select is((select row(user_id, legal_name, nik_enc, enc_key_version, status::text, closed)::text
           from api.svc_kyc(array['00000000-0000-0000-0000-0000000000b1'::uuid])),
          row('00000000-0000-0000-0000-0000000000b1'::uuid, 'Budi Santoso', '\x0b01'::bytea, 2::smallint,
              'approved', false)::text, 'svc_kyc: nama, ciphertext NIK, versi kunci, status');
select is((select count(*)::int from api.svc_kyc(array['00000000-0000-0000-0000-0000000000c1'::uuid])), 0,
          'svc_kyc: user tanpa KYC tidak menghasilkan baris');
select is((select row(user_id, reward_type_id, data_enc)::text from api.svc_recipients(array[(select id from t_rcp where k = 'b')])),
          row('00000000-0000-0000-0000-0000000000b1'::uuid, '00000000-0000-0000-0000-0000000000ff'::uuid, '\x0b03'::bytea)::text,
          'svc_recipients: pemilik, reward type, ciphertext');
select is(api.svc_platform_roles('00000000-0000-0000-0000-0000000000f1'), array['admin_moderator', 'admin_finance'],
          'svc_platform_roles: role admin target');
select is(api.svc_platform_roles('00000000-0000-0000-0000-0000000000b1'), '{}'::text[], 'svc_platform_roles: user biasa kosong');
select is(api.svc_admin_ids(array['admin_finance']), array['00000000-0000-0000-0000-0000000000f1'::uuid],
          'G-12 svc_admin_ids: penerima alert = admin dengan role itu');
select is(api.svc_admin_ids(array['admin_ops']), '{}'::uuid[], 'svc_admin_ids: role tanpa admin → kosong');
reset role;

-- Consent: share_with_brand dicek belum dicabut; dokumen legal harus versi terbaru.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}';
select api.record_consent('share_with_brand');
reset role;
insert into member.consents (user_id, kind, version) values ('00000000-0000-0000-0000-0000000000b1', 'privacy', '2026-09-01');
set local role service_role;
select ok(api.svc_has_consent('00000000-0000-0000-0000-0000000000b1', 'share_with_brand'), 'consent share_with_brand aktif');
select ok(not api.svc_has_consent('00000000-0000-0000-0000-0000000000c1', 'share_with_brand'), 'tanpa consent → false');
select ok(not api.svc_has_consent('00000000-0000-0000-0000-0000000000b1', 'privacy'), 'privasi versi lama bukan consent aktif');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}';
select api.record_consent('share_with_brand', null, false);
reset role;
set local role service_role;
select ok(not api.svc_has_consent('00000000-0000-0000-0000-0000000000b1', 'share_with_brand'), 'consent dicabut → false');
reset role;

-- Web push: daftar langganan, tandai dipakai, hapus endpoint mati.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}';
select api.save_push_subscription('https://push.contoh.id/b-1', 'pk1', 'as1');
select api.save_push_subscription('https://push.contoh.id/b-2', 'pk2', 'as2');
reset role;
set local role service_role;
select is((select array_agg(endpoint || '|' || p256dh || '|' || auth_secret order by endpoint)
           from api.svc_push_subscriptions('00000000-0000-0000-0000-0000000000b1')),
          array['https://push.contoh.id/b-1|pk1|as1', 'https://push.contoh.id/b-2|pk2|as2'],
          'svc_push_subscriptions: endpoint + kunci langganan');
select api.svc_touch_push('https://push.contoh.id/b-1');
select api.svc_delete_push('https://push.contoh.id/b-2');
reset role;
select isnt((select last_used_at from member.push_subscriptions where endpoint = 'https://push.contoh.id/b-1'), null,
            'svc_touch_push mengisi last_used_at');
select is((select count(*)::int from member.push_subscriptions where endpoint = 'https://push.contoh.id/b-2'), 0,
          'svc_delete_push menghapus endpoint mati');

-- Expo push receipt (job:push-receipts): ticket per kiriman di member.push_tickets, bukan kolom di langganan.
select hasnt_column('member', 'push_subscriptions', 'expo_ticket', 'ticket Expo tidak lagi disimpan di push_subscriptions');
select hasnt_function('api', 'svc_touch_push', array['text', 'text'], 'svc_touch_push tanpa parameter ticket');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}';
select api.save_expo_push_token('ExponentPushToken[svcsvcsvcsvcsvcs]');
select api.save_expo_push_token('ExponentPushToken[deaddeaddeaddead]');
reset role;
set local role service_role;
select api.svc_add_push_tickets(array['ExponentPushToken[svcsvcsvcsvcsvcs]', 'ExponentPushToken[deaddeaddeaddead]',
                                      'ExponentPushToken[hilanghilanghila]'],
                                array['ticket-ok', 'ticket-dead', 'ticket-hilang']);
select api.svc_add_push_tickets(array['ExponentPushToken[svcsvcsvcsvcsvcs]'], array['ticket-ok']);
select throws_ok($$ select api.svc_add_push_tickets(array['ExponentPushToken[svcsvcsvcsvcsvcs]'], array['a', 'b']) $$, '22023', null,
                 'svc_add_push_tickets: endpoint & ticket harus berpasangan');
reset role;
select is((select array_agg(ticket || '|' || endpoint order by ticket) from member.push_tickets),
          array['ticket-dead|ExponentPushToken[deaddeaddeaddead]', 'ticket-ok|ExponentPushToken[svcsvcsvcsvcsvcs]'],
          'svc_add_push_tickets: ticket per token, token yang sudah dihapus dilewati, ticket ganda diabaikan');
set local role service_role;
select is((select count(*)::int from api.svc_due_push_tickets()), 0, 'svc_due_push_tickets: ticket < 15 menit belum dicek');
reset role;
update member.push_tickets set created_at = now() - interval '20 minutes';
insert into member.push_tickets (ticket, endpoint, created_at)
values ('ticket-basi', 'ExponentPushToken[svcsvcsvcsvcsvcs]', now() - interval '25 hours');
set local role service_role;
select is((select array_agg(ticket order by ticket) from api.svc_due_push_tickets()), array['ticket-basi', 'ticket-dead', 'ticket-ok'],
          'svc_due_push_tickets: ticket ≥ 15 menit');
select is((select count(*)::int from api.svc_due_push_tickets(1)), 1, 'svc_due_push_tickets: p_limit dipatuhi');
select is(api.svc_resolve_push_tickets(array['ticket-ok'], array['ExponentPushToken[deaddeaddeaddead]']),
          '{"resolved": 1, "removed": 1, "expired": 1}'::jsonb,
          'svc_resolve_push_tickets: ticket terbaca, token mati, ticket > 24 jam');
reset role;
select is((select count(*)::int from member.push_tickets), 0, 'semua ticket selesai (ticket token mati ikut cascade)');
select is((select array_agg(endpoint order by endpoint) from member.push_subscriptions
           where user_id = '00000000-0000-0000-0000-0000000000b1' and kind = 'expo'),
          array['ExponentPushToken[svcsvcsvcsvcsvcs]'], 'token DeviceNotRegistered dihapus, token sehat tetap');

-- Live Activity iOS: svc_push_subscriptions membawa jenis apns_* + activity_ref supaya bridge bisa memilih token.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}';
select api.save_activity_token(repeat('ab', 32), 'apns_activity', 'payout-1');
reset role;
set local role service_role;
select is((select kind || '|' || activity_ref from api.svc_push_subscriptions('00000000-0000-0000-0000-0000000000b1')
           where kind like 'apns%'), 'apns_activity|payout-1', 'svc_push_subscriptions: jenis apns_activity + activity_ref');
reset role;

-- Handoff sesi app native → web (session-handoff): kode sekali pakai 60 detik, maks 10 aktif per user.
set local role service_role;
select is(api.svc_create_handoff('00000000-0000-0000-0000-0000000000c1', sha256('kode-1'::bytea), 'https://app.contoh.id/wallet'),
          now() + interval '60 seconds', 'svc_create_handoff: berlaku 60 detik');
select is((select row(user_id, next)::text from api.svc_redeem_handoff(sha256('kode-1'::bytea))),
          row('00000000-0000-0000-0000-0000000000c1'::uuid, 'https://app.contoh.id/wallet')::text,
          'svc_redeem_handoff: user + next');
select is((select count(*)::int from api.svc_redeem_handoff(sha256('kode-1'::bytea))), 0, 'svc_redeem_handoff: sekali pakai');
select is((select count(*)::int from api.svc_redeem_handoff(sha256('kode-tak-dikenal'::bytea))), 0, 'kode tak dikenal → kosong');
select api.svc_create_handoff('00000000-0000-0000-0000-0000000000c1', sha256('kode-2'::bytea), 'https://accounts.contoh.id/kyc');
reset role;
update member.session_handoffs set expires_at = now() - interval '1 second' where code_hash = sha256('kode-2'::bytea);
set local role service_role;
select is((select count(*)::int from api.svc_redeem_handoff(sha256('kode-2'::bytea))), 0, 'svc_redeem_handoff: kode kedaluwarsa ditolak');
reset role;
select isnt((select used_at from member.session_handoffs where code_hash = sha256('kode-1'::bytea)), null,
            'kode terpakai ditandai used_at');
select is((select used_at from member.session_handoffs where code_hash = sha256('kode-2'::bytea)), null,
          'kode kedaluwarsa tidak ditandai terpakai');
insert into member.session_handoffs (code_hash, user_id, next, expires_at)
values (sha256('kode-basi'::bytea), '00000000-0000-0000-0000-0000000000d1', 'https://app.contoh.id/', now() - interval '2 days');
set local role service_role;
select lives_ok($$ select api.svc_create_handoff('00000000-0000-0000-0000-0000000000d1', sha256(('d-' || i)::bytea), 'https://app.contoh.id/')
                   from generate_series(1, 10) i $$, '10 kode aktif per user boleh');
select throws_ok($$ select api.svc_create_handoff('00000000-0000-0000-0000-0000000000d1', sha256('d-11'::bytea), 'https://app.contoh.id/') $$,
                 '54000', null, 'kode ke-11 yang belum kedaluwarsa ditolak (rate limit)');
reset role;
select is((select count(*)::int from member.session_handoffs where code_hash = sha256('kode-basi'::bytea)), 0,
          'baris kedaluwarsa > 1 hari dibuang saat kode baru dibuat');
set local role service_role;
select lives_ok($$ select api.svc_create_handoff('00000000-0000-0000-0000-0000000000e1', sha256('e-1'::bytea), 'https://app.contoh.id/') $$,
                'rate limit per user: user lain tetap bisa');
reset role;

-- Unduh data saya: hanya baris milik sendiri, ciphertext ikut sebagai hex bytea.
set local role service_role;
select is((api.svc_my_data('00000000-0000-0000-0000-0000000000b1') -> 'kyc' ->> 'nik_enc'), '\x0b01',
          'svc_my_data: ciphertext NIK sebagai hex bytea');
select is(jsonb_array_length(api.svc_my_data('00000000-0000-0000-0000-0000000000b1') -> 'payout_methods'), 1,
          'svc_my_data: hanya rekening milik sendiri');
select is((api.svc_my_data('00000000-0000-0000-0000-0000000000b1') -> 'recipients' -> 0 ->> 'data_enc'), '\x0b03',
          'svc_my_data: data penerima terenkripsi');
select is((api.svc_my_data('00000000-0000-0000-0000-0000000000b1') -> 'account' ->> 'email'), 'b1@contoh.id',
          'svc_my_data: email akun');
select is(jsonb_array_length(api.svc_my_data('00000000-0000-0000-0000-0000000000b1') -> 'consents'), 2,
          'svc_my_data: riwayat consent (aktif + dicabut)');

-- Audit dari Edge Function: format action dijaga CHECK.
select lives_ok($$ select api.svc_audit('00000000-0000-0000-0000-0000000000f1', 'pii.export_payouts', 'batch:x', '{"rows":3}') $$,
                'svc_audit mencatat akses PII');
select throws_ok($$ select api.svc_audit(null, 'Export', 'batch:x') $$, '23514', null, 'action di luar format ditolak');
reset role;

-- Hapus akun A (ter-ban, KYC approved → wajib simpan pajak): tombstone hash + ciphertext; rekening hanya hash.
set local role service_role;
select is(api.svc_close_member('00000000-0000-0000-0000-0000000000a1', true, (current_date + interval '10 years')::date),
          '{"kyc": "tombstoned", "payout_methods_deleted": 0, "payout_methods_tombstoned": 1}'::jsonb,
          'A: KYC & rekening jadi tombstone');
reset role;
select is((select row(user_id, blocked, nik_hash is not null, nik_enc, legal_name, nik_last4, doc_ref)::text
           from member.kyc_records where nik_hash = sha256('NIK-A'::bytea)),
          row(null::uuid, true, true, '\x0a01'::bytea, 'Andi Saputra', null::text, null::text)::text,
          'tombstone KYC A: hash + ciphertext + nama (pajak), tanpa foto & last4');
select is((select row(user_id, blocked, account_no_hash is not null, account_no_enc, account_last4, account_name)::text
           from member.payout_methods where id = (select id from t_pm where k = 'a')),
          row(null::uuid, true, true, null::bytea, null::text, null::text)::text, 'tombstone rekening A: hanya hash');
select lives_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1' $$,
                'user Auth A bisa dihapus setelah keputusan retensi');
set local role service_role;
select throws_ok($$ select api.store_kyc('00000000-0000-0000-0000-0000000000c1', sha256('NIK-A'::bytea), '\x01', '0001', 1::smallint,
                                         'Andi Saputra', '00000000-0000-0000-0000-0000000000c1/ktp.jpg') $$,
                 '23505', 'NIK sudah dipakai akun lain', 'tombstone menyimpan HMAC: NIK akun ter-ban tidak bisa daftar ulang');
select api.store_kyc('00000000-0000-0000-0000-0000000000c1', sha256('NIK-C'::bytea), '\x0c01', '0003', 1::smallint,
                     'Citra Lestari', '00000000-0000-0000-0000-0000000000c1/ktp.jpg');
reset role;
update member.kyc_records set status = 'approved', decided_at = now() where user_id = '00000000-0000-0000-0000-0000000000c1';
set local role service_role;
select throws_ok($$ select api.store_payout_method('00000000-0000-0000-0000-0000000000c1', 'bank', 'BCA', sha256('ACC-A'::bytea), '\x01', '4567', 1::smallint, 'Citra Lestari') $$,
                 '23505', null, 'tombstone menyimpan HMAC: rekening akun ter-ban tidak bisa dipakai lagi');
select is((select row(legal_name, nik_enc, closed)::text from api.svc_kyc(array['00000000-0000-0000-0000-0000000000a1'::uuid])),
          row('Andi Saputra', '\x0a01'::bytea, true)::text, 'svc_kyc: tombstone pajak tetap ditemukan lewat user_id lama');
select is(api.svc_check_ids(array['00000000-0000-0000-0000-0000000000a1'::uuid, '00000000-0000-0000-0000-0000000000b1'::uuid],
                            array[(select id from t_pm where k = 'a'), (select id from t_pm where k = 'b')],
                            array[(select id from t_rcp where k = 'b'), '00000000-0000-0000-0000-000000000077'::uuid]),
          jsonb_build_object('user_ids', jsonb_build_array('00000000-0000-0000-0000-0000000000a1'),
                             'method_ids', jsonb_build_array((select id from t_pm where k = 'a')),
                             'recipient_refs', jsonb_build_array('00000000-0000-0000-0000-000000000077')),
          'svc_check_ids: user terhapus, rekening tombstone, dan penerima tak dikenal dilaporkan hilang');
select is(api.svc_check_ids(null, '{}', null), '{"user_ids": [], "method_ids": [], "recipient_refs": []}'::jsonb,
          'svc_check_ids: input kosong/null aman');

-- Hapus akun B (tidak di-ban, KYC approved): ciphertext disimpan untuk pajak tanpa hash → NIK boleh dipakai lagi.
select is(api.svc_close_member('00000000-0000-0000-0000-0000000000b1', false, (current_date + interval '10 years')::date),
          '{"kyc": "tombstoned", "payout_methods_deleted": 1, "payout_methods_tombstoned": 0}'::jsonb,
          'B: KYC tombstone pajak, rekening dihapus');
reset role;
select is((select row(blocked, nik_hash, nik_enc, legal_name)::text from member.kyc_records where nik_enc = '\x0b01'),
          row(false, null::bytea, '\x0b01'::bytea, 'Budi Santoso')::text, 'tombstone pajak B tanpa hash NIK');
select lives_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-0000000000b1' $$, 'user Auth B terhapus');
select is((select count(*)::int from member.recipient_details where user_id = '00000000-0000-0000-0000-0000000000b1'), 0,
          'data penerima B ikut terhapus (cascade)');
set local role service_role;
select lives_ok($$ select api.store_kyc('00000000-0000-0000-0000-0000000000d1', sha256('NIK-B'::bytea), '\x0d01', '0002', 1::smallint,
                                        'Budi Santoso', '00000000-0000-0000-0000-0000000000d1/ktp.jpg') $$,
                'NIK akun tidak ter-ban boleh daftar ulang di akun baru');

-- Hapus akun E (KYC pending, tidak di-ban, tanpa kewajiban pajak): baris KYC dihapus.
select is(api.svc_close_member('00000000-0000-0000-0000-0000000000e1', false, null),
          '{"kyc": "deleted", "payout_methods_deleted": 0, "payout_methods_tombstoned": 0}'::jsonb, 'E: KYC dihapus');
select is(api.svc_close_member('00000000-0000-0000-0000-0000000000e1', false, null),
          '{"kyc": "none", "payout_methods_deleted": 0, "payout_methods_tombstoned": 0}'::jsonb, 'panggilan ulang idempoten');
select throws_ok($$ select api.svc_close_member('00000000-0000-0000-0000-0000000000c1', false, current_date) $$, '22023', null,
                 'retain_until harus di masa depan');
reset role;
select is((select count(*)::int from member.kyc_records where nik_hash = sha256('NIK-E'::bytea)), 0, 'tidak ada sisa KYC E');
select lives_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-0000000000e1' $$, 'user Auth E terhapus');
select is((select count(*)::int from member.audit_logs where action = 'account.close'), 4, 'setiap penutupan akun tercatat');

select * from finish();
rollback;
