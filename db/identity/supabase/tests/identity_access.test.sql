-- test:rls.access-matrix (identity) + test:member-data.integrity. Jalankan: supabase test db --workdir db/identity
begin;
-- Fixture tes tidak bergantung seed.sql (supabase db reset memuatnya sebelum supabase test db); di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: tabel member + objek bucket identity dikosongkan dulu (di-rollback).
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname = 'member'); end $$;
set local storage.allow_delete_query = 'true';
delete from storage.objects where bucket_id in ('kyc-docs', 'pii-exports', 'payout-proofs');
reset storage.allow_delete_query;
select no_plan();

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@contoh.id'),
  ('00000000-0000-0000-0000-00000000000b', 'b@contoh.id'),
  ('00000000-0000-0000-0000-00000000000c', 'c@contoh.id'),
  ('00000000-0000-0000-0000-0000000000ad', 'mod@contoh.id'),
  ('00000000-0000-0000-0000-0000000000ae', 'support@contoh.id'),
  ('00000000-0000-0000-0000-0000000000af', 'super@contoh.id');
insert into member.platform_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000ad', 'admin_moderator'),
  ('00000000-0000-0000-0000-0000000000ae', 'admin_support'),
  ('00000000-0000-0000-0000-0000000000af', 'admin_super');
insert into member.legal_versions (kind, version, published_at, url) values
  ('tos_clipper', '2026-09-01', now() - interval '40 days', 'https://contoh.id/legal/tos-clipper'),
  ('tos_clipper', '2026-10-01', now() - interval '1 day', 'https://contoh.id/legal/tos-clipper'),
  ('privacy', '2026-10-01', now() - interval '1 day', 'https://contoh.id/legal/privacy'),
  ('tos_brand', '2026-10-01', now() - interval '1 day', 'https://contoh.id/legal/tos-brand');

-- Struktur: semua view api security_invoker; tidak ada fungsi api yang bisa dipanggil anon.
select is((select count(*)::int from pg_class c where c.relnamespace = 'api'::regnamespace and c.relkind = 'v'
            and not coalesce(c.reloptions @> array['security_invoker=true'], false)), 0, 'semua view api security_invoker');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace
            and has_function_privilege('anon', p.oid, 'execute')), 0, 'anon tidak bisa EXECUTE fungsi api apa pun');
select is((select count(*)::int from pg_class c where c.relnamespace = 'member'::regnamespace and c.relkind = 'r'
            and not c.relrowsecurity), 0, 'RLS aktif di semua tabel member');

-- Onboarding clipper A: consent versi lama ditolak, versi terbaru diterima, claim consent_ok ikut berubah.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select throws_ok($$ select api.record_consent('tos_clipper', '2026-09-01') $$, '22023', null, 'consent versi lama ditolak');
select lives_ok($$ select api.record_consent('tos_clipper', '2026-10-01') $$, 'consent ToS clipper terbaru diterima');
select lives_ok($$ select api.record_consent('privacy', '2026-10-01') $$, 'consent privasi diterima');
select throws_ok($$ insert into member.consents (user_id, kind, version) values (auth.uid(), 'kyc', '2026-10-16') $$,
                 '42501', null, 'insert consent langsung ditolak (hanya lewat record_consent)');
reset role;
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-00000000000a","claims":{"sub":"00000000-0000-0000-0000-00000000000a"}}')
           -> 'claims' -> 'consent_ok' ->> 'clipper'), 'false', 'tanpa pernyataan umur 18+, consent_ok.clipper = false');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select lives_ok($$ select api.record_consent('age_18_plus') $$, 'pernyataan umur 18+ dicatat');
reset role;
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-00000000000a","claims":{"sub":"00000000-0000-0000-0000-00000000000a"}}')
           -> 'claims' -> 'consent_ok'), '{"brand": false, "clipper": true, "share_with_brand": false}'::jsonb,
          'hook: consent_ok clipper true, brand false, share_with_brand false');
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select api.record_consent('share_with_brand');
reset role;
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-00000000000a","claims":{"sub":"00000000-0000-0000-0000-00000000000a"}}')
           -> 'claims' -> 'consent_ok' ->> 'share_with_brand'), 'true',
          'regresi AC-1: hook mengisi consent_ok.share_with_brand (dibaca core request_fulfillment)');
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-00000000000a","claims":{"sub":"00000000-0000-0000-0000-00000000000a"}}')
           -> 'claims' ->> 'kyc'), 'none', 'hook: kyc none sebelum KYC');
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-0000000000ad","claims":{"sub":"00000000-0000-0000-0000-0000000000ad"}}')
           -> 'claims' -> 'app_roles'), '["admin_moderator"]'::jsonb, 'hook: app_roles dari E-27');
select ok(not has_function_privilege('authenticated', 'member.custom_access_token_hook(jsonb)', 'execute'),
          'browser tidak bisa memanggil hook');

-- KYC & rekening lewat member-data (service role); browser tidak bisa memanggil penyimpan PII.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select throws_ok($$ select api.store_kyc('00000000-0000-0000-0000-00000000000a', sha256('x'::bytea), '\x01', '1234', 1::smallint, 'Andi Saputra', '00000000-0000-0000-0000-00000000000a/ktp.jpg') $$,
                 '42501', null, 'browser tidak bisa memanggil store_kyc');
reset role;
set local role service_role;
select lives_ok($$ select api.store_kyc('00000000-0000-0000-0000-00000000000a', sha256('3171012345670001'::bytea), '\x01', '0001', 1::smallint, 'Andi Saputra', '00000000-0000-0000-0000-00000000000a/ktp.jpg') $$,
                'KYC A tersimpan (pending)');
select throws_ok($$ select api.store_kyc('00000000-0000-0000-0000-00000000000a', sha256('3171012345670001'::bytea), '\x01', '0001', 1::smallint, 'Andi Saputra', '00000000-0000-0000-0000-00000000000a/ktp.jpg') $$,
                 '23505', null, 'KYC yang masih pending tidak bisa dikirim ulang');
select throws_ok($$ select api.store_kyc('00000000-0000-0000-0000-00000000000b', sha256('3171012345670001'::bytea), '\x01', '0001', 1::smallint, 'Budi', '00000000-0000-0000-0000-00000000000b/ktp.jpg') $$,
                 '23505', 'NIK sudah dipakai akun lain', 'FR-04: NIK yang sama di akun lain ditolak');
select throws_ok($$ select api.store_payout_method('00000000-0000-0000-0000-00000000000a', 'bank', 'BCA', sha256('8881234567'::bytea), '\x01', '4567', 1::smallint, 'Andi S') $$,
                 '22023', 'nama pemilik rekening harus sama dengan nama KYC', 'nama rekening beda dari nama KYC ditolak');
select lives_ok($$ select api.store_payout_method('00000000-0000-0000-0000-00000000000a', 'bank', 'BCA', sha256('8881234567'::bytea), '\x01', '4567', 1::smallint, '  andi   SAPUTRA ') $$,
                'nama rekening = nama KYC (beda spasi/kapital) diterima');
select throws_ok($$ select api.store_payout_method('00000000-0000-0000-0000-00000000000b', 'bank', 'BCA', sha256('8881234567'::bytea), '\x01', '4567', 1::smallint, 'Budi') $$,
                 '22023', 'lengkapi KYC dulu', 'rekening tanpa KYC ditolak');
reset role;

-- RLS data sendiri.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select is((select count(*)::int from api.my_kyc), 1, 'A melihat KYC miliknya');
select is((select account_last4 from api.my_payout_methods()), '4567', 'A melihat rekening tersamar miliknya');
select throws_ok($$ select nik_hash from member.kyc_records $$, '42501', null, 'kolom nik_hash tidak bisa dibaca browser');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}';
select is((select count(*)::int from api.my_kyc), 0, 'B tidak melihat KYC A');
select is((select count(*)::int from api.my_payout_methods()), 0, 'B tidak melihat rekening A');
reset role;
set local role anon;
select throws_ok($$ select * from api.my_kyc $$, '42501', null, 'anon tidak bisa membaca my_kyc');
select is((select count(*)::int from api.legal_versions), 4, 'anon bisa membaca versi dokumen legal');
reset role;

-- Keputusan KYC: hanya admin_moderator dengan aal2; tercatat di audit log append-only.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated","aal":"aal1"}';
select throws_ok($$ select api.admin_kyc_decision('00000000-0000-0000-0000-00000000000a', 'approved') $$, '42501', null,
                 'admin tanpa aal2 ditolak');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ae","role":"authenticated","aal":"aal2"}';
select throws_ok($$ select api.admin_kyc_decision('00000000-0000-0000-0000-00000000000a', 'approved') $$, '42501', null,
                 'admin_support (bukan reviewer KYC) ditolak');
select is((select count(*)::int from api.admin_read('00000000-0000-0000-0000-00000000000a')), 1, 'admin_support boleh baca (tercatat)');
select throws_ok($$ select * from api.admin_kyc_queue() $$, '42501', null, 'admin_support tidak melihat antrean KYC');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated","aal":"aal2"}';
select is((select array_agg(user_id) from api.admin_kyc_queue()), array['00000000-0000-0000-0000-00000000000a'::uuid],
          'antrean KYC pending untuk reviewer (tanpa PII)');
select throws_ok($$ select * from api.admin_list_roles() $$, '42501', null, 'daftar admin hanya admin_super');
select is((select count(*)::int from api.audit_logs), 0, 'audit log identity hanya admin_super');
select lives_ok($$ select api.admin_kyc_decision('00000000-0000-0000-0000-00000000000a', 'approved') $$, 'admin_moderator aal2 menyetujui KYC');
select is((select count(*)::int from api.admin_kyc_queue()), 0, 'KYC yang diputus keluar dari antrean pending');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000af","role":"authenticated","aal":"aal2"}';
select is((select string_agg(email || '=' || array_to_string(roles, ','), ' ' order by email) from api.admin_list_roles()),
          'mod@contoh.id=admin_moderator super@contoh.id=admin_super support@contoh.id=admin_support', 'admin_super melihat daftar admin + role');
select ok((select count(*) > 0 from api.audit_logs where action = 'kyc.decide'), 'admin_super membaca audit log identity');
-- Regresi audit AA-20 (§4 "akun admin dibuat terpisah dari akun clipper/brand"): akun yang setuju ToS clipper/brand tidak bisa jadi admin.
select throws_ok($$ select api.admin_set_role('00000000-0000-0000-0000-00000000000a', 'admin_support', true) $$, '22023',
                 'admin_account_must_be_separate', 'regresi AA-20: akun clipper tidak bisa diberi role admin');
select lives_ok($$ select api.admin_set_role('00000000-0000-0000-0000-00000000000c', 'admin_support', true) $$,
                'akun tanpa ToS clipper/brand bisa dijadikan admin');
select lives_ok($$ select api.admin_set_role('00000000-0000-0000-0000-0000000000ad', 'admin_finance', true) $$,
                'admin yang sudah ada bisa diberi role kedua');
select api.admin_set_role('00000000-0000-0000-0000-00000000000c', 'admin_support', false);
select api.admin_set_role('00000000-0000-0000-0000-0000000000ad', 'admin_finance', false);
reset role;
select is((member.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-00000000000a","claims":{}}') -> 'claims' ->> 'kyc'),
          'approved', 'hook: claim kyc approved');
select is((select count(*)::int from member.audit_logs where action in ('kyc.submit', 'kyc.decide', 'pii.read')), 3,
          'submit, baca, dan keputusan KYC tercatat');
select throws_ok($$ update member.audit_logs set action = 'x.y' $$, '42501', null, 'audit log tidak bisa diubah');

-- Storage kyc-docs: folder milik sendiri; reviewer KYC bisa membaca, admin_support tidak.
insert into storage.buckets (id, name, public) values ('kyc-docs', 'kyc-docs', false) on conflict (id) do nothing;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}';
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('kyc-docs', '00000000-0000-0000-0000-00000000000a/ktp.jpg') $$,
                'A unggah KTP ke foldernya');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('kyc-docs', '00000000-0000-0000-0000-00000000000b/ktp.jpg') $$,
                 '42501', null, 'A tidak bisa unggah ke folder B');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ae","role":"authenticated","aal":"aal2"}';
select is((select count(*)::int from storage.objects where bucket_id = 'kyc-docs'), 0, 'admin_support tidak bisa melihat foto KTP');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000ad","role":"authenticated","aal":"aal2"}';
select is((select count(*)::int from storage.objects where bucket_id = 'kyc-docs'), 1, 'reviewer KYC bisa melihat foto KTP');
reset role;

-- Hapus akun (alur 7): wajib putuskan retensi dulu; akun ter-ban menyisakan hash sehingga NIK tidak bisa dipakai lagi.
select throws_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-00000000000a' $$, '23514', null,
                 'hapus user tanpa keputusan retensi KYC ditolak');
update member.kyc_records set blocked = true where user_id = '00000000-0000-0000-0000-00000000000a';
update member.payout_methods set blocked = true where user_id = '00000000-0000-0000-0000-00000000000a';
select lives_ok($$ delete from auth.users where id = '00000000-0000-0000-0000-00000000000a' $$, 'user ter-ban dihapus, tombstone tersisa');
select lives_ok($$ update member.kyc_records set nik_enc = null, nik_last4 = null, legal_name = null, doc_ref = null
                    where user_id is null and blocked $$, 'PII tombstone dibuang, hash tetap');
select lives_ok($$ update member.payout_methods set account_no_enc = null, account_last4 = null, account_name = null
                    where user_id is null and blocked $$, 'rekening tombstone tinggal hash');
select is((select count(*)::int from member.kyc_records where user_id is null and blocked and nik_hash is not null
            and nik_enc is null and legal_name is null), 1, 'tombstone KYC hanya berisi hash');
set local role service_role;
select throws_ok($$ select api.store_kyc('00000000-0000-0000-0000-00000000000c', sha256('3171012345670001'::bytea), '\x01', '0001', 1::smallint, 'Andi Saputra', '00000000-0000-0000-0000-00000000000c/ktp.jpg') $$,
                 '23505', 'NIK sudah dipakai akun lain', 'NIK akun ter-ban tidak bisa dipakai daftar ulang');
reset role;

-- Web push PWA (F-C14): langganan per perangkat, pindah akun kalau perangkat dipakai akun lain.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}';
select lives_ok($$ select api.save_push_subscription('https://push.contoh.id/ep-1', 'k1', 'a1') $$, 'B menyimpan langganan push');
select is((select count(*)::int from api.push_subscriptions), 1, 'B melihat langganannya');
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}';
select is((select count(*)::int from api.push_subscriptions), 0, 'C tidak melihat langganan B');
select lives_ok($$ select api.save_push_subscription('https://push.contoh.id/ep-1', 'k2', 'a2') $$, 'perangkat yang sama login sebagai C');
select is((select count(*)::int from api.push_subscriptions), 1, 'langganan pindah ke C');
reset role;
select ok(not has_column_privilege('authenticated', 'member.push_subscriptions', 'auth_secret', 'select'),
          'kunci langganan push tidak bisa dibaca browser');

-- Regresi 2026-10-19: enum internal di parameter RPC → 42501 lewat REST walau pgTAP (literal) lulus.
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api' and exists (select 1 from unnest(p.proargtypes) t join pg_type ty on ty.oid = t
              join pg_namespace tn on tn.oid = ty.typnamespace where tn.nspname not in ('pg_catalog', 'api', 'extensions'))),
          null, 'argumen fungsi api tidak bertipe schema internal (PostgREST meng-cast argumen; role API tanpa USAGE schema itu)');
select * from finish();
rollback;
