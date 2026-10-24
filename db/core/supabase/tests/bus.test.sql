-- Bus antar database (schemas/bus/bus.sql): outbox, relay (pg_net + HMAC), penerima idempoten.
begin;
select no_plan();

-- allowlist bus (bus/accept.sql) + topik & tabel uji file ini (di-rollback bersama tes)
alter function bus.accepts(text, text) rename to accepts_real;
create function bus.accepts(p_source text, p_table text) returns text[] language sql as $$
  select case p_table when 'public.rep_dst' then array['a'] when 'public.rep_part' then array['status']
                      when 'public.rc_dst' then array['a'] when 'public.rc_mixed' then array['a'] when 'public.rc_part' then array['a'] when 'public.rc_child' then array['parent_id'] else bus.accepts_real(p_source, p_table) end;
$$;
alter function bus.accepts_topic(text, text) rename to accepts_topic_real;
create function bus.accepts_topic(p_source text, p_topic text) returns boolean language sql as $$
  select p_topic like 'test.%' or bus.accepts_topic_real(p_source, p_topic);
$$;

create table public.bus_test_log (v text);
create function bus_in.test_ping(p jsonb) returns void language plpgsql as $$
begin
  insert into public.bus_test_log (v) values (p ->> 'v');
end $$;

-- ===== penerima =====
select is(api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000b1","topic":"test.ping","payload":{"v":"a"}},
                                        {"id":"00000000-0000-0000-0000-0000000000b2","topic":"test.ping","payload":{"v":"b"}}]'),
          '{"applied": 2, "skipped": 0}'::jsonb, 'batch diterapkan berurutan');
select is(api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000b2","topic":"test.ping","payload":{"v":"b"}},
                                        {"id":"00000000-0000-0000-0000-0000000000b3","topic":"test.ping","payload":{"v":"c"}}]'),
          '{"applied": 1, "skipped": 1}'::jsonb, 'kiriman ulang: event yang sudah diterima dilewati (idempoten)');
select is((select array_agg(v order by v) from public.bus_test_log), array['a', 'b', 'c'], 'handler jalan sekali per event');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000b4","topic":"test.ping","payload":{"v":"d"}},
                                                        {"id":"00000000-0000-0000-0000-0000000000b5","topic":"test.unknown","payload":{}}]') $$,
                 'P0001', 'bus_no_handler:test.unknown', 'topic tanpa handler menolak batch');
select ok(not exists (select 1 from public.bus_test_log where v = 'd') and not exists (select 1 from bus.inbox where id = '00000000-0000-0000-0000-0000000000b4'),
          'batch yang ditolak tidak meninggalkan efek sebagian (satu transaksi)');
select is((select source from bus.inbox where id = '00000000-0000-0000-0000-0000000000b1'), 'creator', 'inbox mencatat pengirim');
set local role authenticated;
select throws_ok($$ select api.bus_receive('creator', '[]') $$, '42501', null, 'bus_receive hanya service role');
reset role;

-- ===== pengirim =====
delete from vault.secrets where name in ('bus_url_brand', 'bus_secret_brand');  -- mandiri dari isi Vault dev-stack (di-rollback)
delete from bus.outbox where target = 'brand';
select bus.emit('brand', 'test.ping', '{"v":"x1"}');
select bus.emit('brand', 'test.ping', '{"v":"x2"}');
select bus.relay();
select ok((select bool_and(last_error like 'vault bus_url_/bus_secret_brand%') from bus.outbox where target = 'brand'),
          'relay tanpa secret Vault: tidak mengirim, error tercatat');
select vault.create_secret('http://brand.test', 'bus_url_brand');
select vault.create_secret('rahasia-admin-ke-brand', 'bus_secret_brand');
select is(bus.relay(), 2, 'relay mengirim batch 2 event');
select is((select count(distinct request_id)::int from bus.outbox where target = 'brand'), 1, 'satu request per batch');
create temp table t_req as
select q.* from net.http_request_queue q where q.id = (select max(request_id) from bus.outbox where target = 'brand');
select is((select url from t_req), 'http://brand.test/functions/v1/bridge', 'ke bridge penerima');
select is((select headers ->> 'x-bridge-sig' from t_req),
          (select encode(extensions.hmac((headers ->> 'x-bridge-ts') || '.' || convert_from(body, 'UTF8'), 'rahasia-admin-ke-brand', 'sha256'), 'hex') from t_req),
          'tanda tangan HMAC cocok dengan byte body yang benar-benar dikirim pg_net');
select is((select convert_from(body, 'UTF8')::jsonb #>> '{payload,source}' from t_req), 'admin', 'pengirim = bus.me()');
select is((select jsonb_agg(e #>> '{payload,v}') from t_req, jsonb_array_elements(convert_from(body, 'UTF8')::jsonb #> '{payload,events}') e),
          '["x1", "x2"]'::jsonb, 'urutan event = urutan seq');
select is(bus.relay(), 0, 'selama batch belum dijawab tidak ada kiriman baru');

-- jawaban gagal → backoff, batch tidak dikirim ulang sebelum next_at; event baru tidak menyalip
insert into net._http_response (id, status_code, content, timed_out, created)
select max(request_id), 500, 'boom', false, now() from bus.outbox where target = 'brand';
select bus.emit('brand', 'test.ping', '{"v":"x3"}');
select is(bus.relay(), 0, 'jawaban 500 → batch ditahan backoff, event baru tidak menyalip');
select ok((select bool_and(attempts = 1 and request_id is null and next_at > now() and last_error like 'http 500%')
             from bus.outbox where target = 'brand' and payload ->> 'v' in ('x1', 'x2')), 'percobaan tercatat + backoff');
update bus.outbox set next_at = now() - interval '1 second' where target = 'brand';
select is(bus.relay(), 3, 'setelah backoff: batch dikirim ulang bersama event baru, urut');
insert into net._http_response (id, status_code, content, timed_out, created)
select max(request_id), 200, '{"ok":true}', false, now() from bus.outbox where target = 'brand';
select bus.relay();
select ok((select bool_and(sent_at is not null) from bus.outbox where target = 'brand'), 'jawaban 200 → batch ditandai terkirim');
select is(bus.relay(), 0, 'tidak ada yang tersisa');
select bus.emit('brand', 'test.ping', '{"v":"y1"}');
select bus.emit('brand', 'test.ping', '{"v":"y2"}');
update bus.outbox set attempts = 3 where target = 'brand' and sent_at is null;
select is(bus.relay(), 1, 'O1-C6: kepala gagal ≥ 3 kali → dikirim sendiri (kepala = event yang gagal)');
delete from bus.outbox where target = 'brand' and sent_at is null;

-- ===== replikasi baris =====
create table public.rep_src (id int primary key, a text, b text not null default 'milik-lain');
create trigger rep_src_replicate after insert or update or delete on public.rep_src for each row execute function bus.replicate('creator:a');
delete from bus.outbox where target = 'creator';
insert into public.rep_src (id, a) values (1, 'satu');
update public.rep_src set b = 'diubah-pemilik-lain' where id = 1;
update public.rep_src set a = 'satu-baru' where id = 1;
delete from public.rep_src where id = 1;
select is((select jsonb_agg(payload order by seq) from bus.outbox where target = 'creator' and topic = 'rep.row'),
          '[{"op":"upsert","key":{"id":1},"row":{"a":"satu","id":1},"table":"public.rep_src"},
            {"op":"upsert","key":{"id":1},"row":{"a":"satu-baru","id":1},"table":"public.rep_src"},
            {"op":"delete","key":{"id":1},"row":null,"table":"public.rep_src"}]'::jsonb,
          'replikasi: hanya kolom milik sendiri + pk; update kolom milik project lain tidak dikirim; delete ikut');

-- Review CL4: retensi — hanya outbox terkirim > 14 hari yang dihapus (yang belum terkirim tidak pernah); inbox sengaja tidak
-- dipangkas (CX7: id inbox = satu-satunya pencegah perintah diterapkan dua kali)
insert into bus.outbox (target, topic, payload, sent_at, created_at) values
  ('creator', 'uji.prune', '{"lama":true}', now() - interval '15 days', now() - interval '15 days'),
  ('creator', 'uji.prune', '{"baru":true}', now() - interval '1 day', now() - interval '1 day'),
  ('creator', 'uji.prune', '{"belum":true}', null, now() - interval '40 days');
insert into bus.inbox (id, source, topic, received_at) values ('00000000-0000-0000-0000-0000000000d7', 'creator', 'uji.prune', now() - interval '31 days')
  on conflict (id) do update set received_at = excluded.received_at;
select bus.prune();
select is((select array_agg(payload::text order by created_at) from bus.outbox where topic = 'uji.prune'), array['{"belum": true}', '{"baru": true}'],
          'CL4: outbox terkirim > 14 hari dihapus; yang belum terkirim & yang baru tetap');
select ok(exists (select 1 from bus.inbox where id = '00000000-0000-0000-0000-0000000000d7'),
          'CX7: inbox tidak dipangkas — kiriman ulang batch yang ack-nya hilang tetap dikenali duplikat, berapa lama pun pengirim mati');
delete from bus.outbox where topic = 'uji.prune';

-- Review Claude C3 (+ CX1): pengirim hanya bisa menulis tabel & kolom yang memang direplikasi pemiliknya ke sini; di luar itu
-- (tabel/kolom yang ada di sini) dilewati + alert (tidak raise: kontrak lama yang masih antre sesudah upgrade tidak boleh
-- memacetkan antrean); yang belum ada di sini = penerima belum upgrade → raise (antrean ditahan, data tidak hilang, CL7)
create temp table t_c3 as select coalesce(max(id), 0) m from ops.alerts;
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e1","topic":"rep.row","payload":{"op":"upsert","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":{"id":"11111111-0000-0000-0000-00000000000a","status":"active","trust_score":100},"table":"market.profiles"}}]') $$,
                'C3/CX1: kolom milik admin dari creator tidak menahan antrean');
select ok(not exists (select 1 from market.profiles where id = '11111111-0000-0000-0000-00000000000a' and trust_score = 100),
          'C3: creator tidak bisa menulis kolom milik admin (status/trust profil)');
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e2","topic":"rep.row","payload":{"op":"upsert","key":{"key":"x.c3"},"row":{"key":"x.c3","value":"1"},"table":"ops.settings"}}]') $$,
                'C3/CX1: tabel yang tidak direplikasi pengirim tidak menahan antrean');
select ok(not exists (select 1 from ops.settings where key = 'x.c3'), 'C3: tabel yang tidak direplikasi pengirim ke sini tidak ditulis');
select lives_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e3","topic":"rep.row","payload":{"op":"delete","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":null,"table":"market.profiles"}}]') $$,
                'C3: delete dari pengirim yang tidak berhak tidak menahan antrean');
select is((select array_agg(payload -> 'events' -> 0 ->> 'reason' order by id) from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_c3)),
          array['columns', 'table', 'table'], 'C3/CX1: tiap penolakan dilaporkan (alert bus.rejected_payload)');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c7","topic":"rep.row","payload":{"op":"upsert","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":{"id":"11111111-0000-0000-0000-00000000000a","kolom_baru":"x"},"table":"market.profiles"}}]') $$,
                 'P0001', 'bus_no_column:market.profiles {kolom_baru}', 'CL7: kolom yang belum ada di penerima → antrean ditahan, tidak dibuang');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c8","topic":"rep.row","payload":{"op":"upsert","key":{"id":"x"},"row":{"id":"x"},"table":"market.tabel_baru"}}]') $$,
                 'P0001', 'bus_no_table:market.tabel_baru', 'CL7: tabel yang belum ada di penerima → antrean ditahan');
-- CL8: satu kiriman berisi banyak event yang ditolak = satu alert (jumlah + contoh), bukan satu alert per event
create temp table t_cl8 as select coalesce(max(id), 0) m from ops.alerts;
select api.bus_receive('creator', (select jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  jsonb_build_object('op', 'upsert', 'key', jsonb_build_object('key', 'x.cl8.' || g), 'row', jsonb_build_object('key', 'x.cl8.' || g, 'value', '1'),
                     'table', 'ops.settings'))) from generate_series(1, 30) g));
select is((select string_agg((payload ->> 'count') || ':' || jsonb_array_length(payload -> 'events'), ',') from ops.alerts
            where kind = 'bus.rejected_payload' and id > (select m from t_cl8)), '30:10', 'CL8: 30 event ditolak = 1 alert (30, 10 contoh)');
-- Review R91-1: delete hanya untuk tabel tanpa kolom milik penerima (hapus + kirim ulang tidak bisa mereset status/sanksi admin)
create temp table t_r91 as select count(*) n from ops.alerts where kind = 'bus.rejected_payload';
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000ea","topic":"rep.row","payload":{"op":"delete","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":null,"table":"market.profiles"}}]') $$,
                'R91-1: delete profil dari creator tidak menahan antrean');
select is((select count(*) from ops.alerts where kind = 'bus.rejected_payload'), (select n + 1 from t_r91),
          'R91-1: delete profil (kolom status/sanksi milik admin) dilewati + alert');
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000eb","topic":"rep.row","payload":{"op":"delete","key":{"id":"00000000-0000-0000-0000-0000000000eb"},"row":null,"table":"tracking.social_accounts"}}]') $$,
                'R91-1: delete tabel yang seluruhnya milik pengirim tetap diterima (akun sosmed diputus)');
-- Review C5/R88-1: topik hanya dari pengirim yang memang mengirimnya; sumber ping = pengirim terautentikasi
-- (raise, bukan dilewati — CX5: event yang di-ack sampai ke efek sesudah batch di bridge, mis. hapus file avatar)
select throws_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e4","topic":"submission.post_gone","payload":{"submission_id":"00000000-0000-0000-0000-0000000000e4"}}]') $$,
                 '42501', 'bus_not_allowed:brand submission.post_gone', 'C5: brand tidak bisa memanggil handler milik creator (post_gone)');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e5","topic":"org.owner_lost","payload":{}}]') $$,
                 '42501', 'bus_not_allowed:creator org.owner_lost', 'C5: creator tidak bisa memanggil handler milik brand');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000ef","topic":"topik.baru_belum_ada","payload":{}}]') $$,
                 'P0001', 'bus_no_handler:topik.baru_belum_ada', 'CX1: handler belum ada (penerima belum di-deploy) → antrean ditahan, perintah tidak hilang');
-- CX1: creator/brand melapor penolakan ke admin lewat bus.rejected → alert di admin
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000f0","topic":"bus.rejected","payload":{"source":"brand","count":1,"events":[{"reason":"columns","table":"market.campaigns","columns":["required_hashtags"]}]}}]') $$,
                'CX1: laporan penolakan dari creator diterima');
select is((select payload ->> 'receiver' || ':' || (payload -> 'events' -> 0 ->> 'reason') from ops.alerts where kind = 'bus.rejected_payload' order by id desc limit 1),
          'creator:columns', 'CX1: penolakan di creator jadi alert di admin');
insert into ops.bus_peers (source, pinged_at) values ('creator', '2020-01-01'), ('brand', '2020-01-01')
  on conflict (source) do update set pinged_at = excluded.pinged_at;
select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e6","topic":"bus.ping","payload":{"source":"creator","at":"2099-01-01T00:00:00Z","stuck":[]}}]');
select is((select string_agg(source || ':' || (pinged_at > '2021-01-01')::text, ',' order by source) from ops.bus_peers
            where source in ('brand', 'creator')), 'brand:true,creator:false', 'C5: ping brand yang mengaku creator tercatat sebagai brand');
-- Review C6: notifikasi untuk anggota brand yang profilnya belum tiba dari creator tidak menolak batch (FK lintas sumber dilepas)
select lives_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e7","topic":"notify.user","payload":{"user_id":"00000000-0000-0000-0000-0000000000e7","event":"org.member_added","payload":{}}}]') $$,
                'C6: notify.user untuk profil yang belum tiba diterima');
-- Review C7: isi topik yang diizinkan divalidasi per pengirim — dilewati + alert (tidak menahan antrean)
select lives_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e8","topic":"review.decision","payload":{"target_type":"submission","target_id":"00000000-0000-0000-0000-0000000000e8","decision":"appeal"}},
                                                     {"id":"00000000-0000-0000-0000-0000000000e9","topic":"notify.user","payload":{"user_id":"00000000-0000-0000-0000-0000000000e9","event":"payout.paid","payload":{}}}]') $$,
                'C7: keputusan submisi & notifikasi uang palsu dari brand tidak menolak batch');
select ok(not exists (select 1 from trust.review_decisions where target_id = '00000000-0000-0000-0000-0000000000e8')
          and not exists (select 1 from ops.notifications where user_id = '00000000-0000-0000-0000-0000000000e9'),
          'C7: brand tidak bisa menulis keputusan submisi (banding) atau notifikasi di luar org.*/agency.*/campaign.invited');
select is((select count(*)::int from ops.alerts where kind = 'bus.rejected_payload' and payload ->> 'topic' in ('review.decision', 'notify.user')), 2, 'C7: payload yang dilewati → alert');

-- Review CL6: bus.skip (deploy.sh bus skip) hanya melewati kepala antrean satu target, dengan seq eksplisit
delete from bus.outbox where target = 'brand' and sent_at is null;
insert into bus.outbox (target, topic, payload) values ('brand', 'uji.skip', '{"n":1}'), ('brand', 'uji.skip', '{"n":2}');
create temp table t_cl6 as select min(seq) head, max(seq) nxt from bus.outbox where topic = 'uji.skip';
select throws_ok(format('select bus.skip(%L, %s)', 'brand', (select nxt from t_cl6)), 'P0001', null, 'CL6: seq yang bukan kepala antrean ditolak');
select is((select bus.skip('brand', (select head from t_cl6)) -> 'payload'), '{"n":1}'::jsonb, 'CL6: isi event yang dilewati dikembalikan');
select is((select string_agg((sent_at is not null)::text || ':' || coalesce(left(last_error, 17), '-'), ',' order by seq) from bus.outbox where topic = 'uji.skip'),
          'true:dilewati operator,false:-', 'CL6: hanya kepala yang ditandai terkirim (dilewati), sisanya tetap antre');
delete from bus.outbox where topic = 'uji.skip';

-- Review CX2/CL3: restore satu DB — rekonsiliasi kunci. Pengirim: semua kunci tabel replika, potongan 1000, potongan terakhir
-- ditandai. Penerima: baris yang tidak ada di pemilik dihapus (tabel milik penuh pengirim); tabel campuran tidak dihapus, dilaporkan.
create table public.rc_src (id int primary key, a text);
create trigger rc_src_replicate after insert or update or delete on public.rc_src for each row execute function bus.replicate('creator:a');
insert into public.rc_src select g, 'x' from generate_series(1, 1500) g;
delete from bus.outbox where payload ->> 'table' = 'public.rc_src';
select is(bus.reconcile('public.rc_src', 'creator'), 1500, 'CX2: reconcile mengirim seluruh kunci pemilik');
select is((select string_agg(jsonb_array_length(payload -> 'keys') || ':' || (payload ->> 'last'), ',' order by seq) from bus.outbox
            where topic = 'rep.keys' and payload ->> 'table' = 'public.rc_src'), '1000:false,500:true', 'CX2: berpotongan 1000, potongan terakhir ditandai');
select is((select payload -> 'total' from bus.outbox where topic = 'rep.keys' and payload ->> 'table' = 'public.rc_src' and payload ->> 'last' = 'true'),
          '1500'::jsonb, 'O1-3: potongan terakhir membawa jumlah kunci (penerima cek kelengkapan)');
select ok('public.rc_src'::regclass in (select bus.replica_tables('creator')), 'CX2: daftar tabel replika ke target (deploy.sh bus reconcile)');
create temp table t_rt as select r, row_number() over () i from bus.replica_tables('creator') r;
select ok(not exists (select 1 from t_rt a join t_rt b on a.i < b.i
                        join pg_constraint c on c.conrelid = a.r and c.confrelid = b.r and c.contype = 'f' and c.conrelid <> c.confrelid),
          'CX2: urut FK — induk sebelum anak (resync tidak menunjuk induk yang belum ada di penerima)');
delete from bus.outbox where payload ->> 'table' = 'public.rc_src';
create table public.rc_dst (id int primary key, a text);
create table public.rc_mixed (id int primary key, a text, milik_lokal text);
insert into public.rc_dst values (1, 'x'), (2, 'dihidupkan restore'), (3, 'x');
insert into public.rc_mixed values (1, 'x', 'l'), (2, 'x', 'l');
create temp table t_cx2 as select coalesce(max(id), 0) m from ops.alerts;
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(
  jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.keys', 'payload', '{"table":"public.rc_dst","epoch":"00000000-0000-0000-0000-0000000000c2","keys":[{"id":1}],"last":false}'::jsonb))) $$,
  'CX2: potongan kunci pertama ditampung');
select is((select count(*)::int from public.rc_dst), 3, 'CX2: belum ada yang dihapus sebelum potongan terakhir');
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(
  jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.keys', 'payload', '{"table":"public.rc_dst","epoch":"00000000-0000-0000-0000-0000000000c2","keys":[{"id":3}],"last":true,"total":2}'::jsonb),
  jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.keys', 'payload', '{"table":"public.rc_mixed","epoch":"00000000-0000-0000-0000-0000000000c3","keys":[{"id":1}],"last":true,"total":1}'::jsonb))) $$,
  'CX2: potongan terakhir diterapkan');
select is((select array_agg(id order by id) from public.rc_dst), array[1, 3], 'CX2: baris yang tidak ada di pemilik (dihidupkan restore) dihapus');
select is((select count(*)::int from public.rc_mixed), 2, 'CX2: tabel campuran tidak dihapus (kolom milik penerima)');
select ok(exists (select 1 from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_cx2) and payload -> 'events' -> 0 ->> 'reason' = 'delete'),
          'CX2: baris tabel campuran yang tidak ada di pemilik dilaporkan');
select is((select count(*)::int from bus.reconcile_keys), 0, 'CX2: penampung kunci dibersihkan');
-- O1-3: potongan awal hilang (dipangkas bus.prune / dilewati bus.skip) → daftar tidak lengkap, tidak ada yang dihapus, dilaporkan.
insert into public.rc_dst values (2, 'x');
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(
  jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.keys', 'payload', '{"table":"public.rc_dst","epoch":"00000000-0000-0000-0000-0000000000c4","keys":[{"id":3}],"last":true,"total":2}'::jsonb))) $$,
  'O1-3: potongan terakhir dari daftar tidak lengkap tidak menahan antrean');
select is((select array_agg(id order by id) from public.rc_dst), array[1, 2, 3], 'O1-3: daftar tidak lengkap → tidak ada baris dihapus');
select ok(exists (select 1 from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_cx2)
                  and payload -> 'events' @> '[{"reason":"reconcile_incomplete","table":"public.rc_dst"}]'), 'O1-3: dilaporkan');
-- O1-2: baris yang tidak boleh dihapus (dirujuk / append-only) dilaporkan; baris lain tetap dihapus, antrean jalan.
create table public.rc_part (id int primary key, a text);
create table public.rc_ref (part_id int references public.rc_part);
insert into public.rc_part values (1, 'x'), (2, 'dirujuk'), (3, 'x');
insert into public.rc_ref values (2);
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(
  jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.keys', 'payload', '{"table":"public.rc_part","epoch":"00000000-0000-0000-0000-0000000000c5","keys":[{"id":1}],"last":true,"total":1}'::jsonb))) $$,
  'O1-2: baris yang gagal dihapus tidak menahan antrean');
select is((select array_agg(id order by id) from public.rc_part), array[1, 2], 'O1-2: baris dirujuk tetap, baris lain dihapus');
select ok(exists (select 1 from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_cx2)
                  and payload -> 'events' @> '[{"reason":"reconcile_delete","table":"public.rc_part","key":{"id":2}}]'), 'O1-2: dilaporkan');
select is((select count(*)::int from bus.reconcile_keys), 0, 'O1-2/O1-3: penampung kunci dibersihkan');
-- O1-C3: resync sesudah restore membawa anak yang induknya hilang bersama DB yang dipulihkan → dilaporkan, antrean jalan;
-- kiriman biasa (induk dari pengirim lain belum tiba) tetap menahan antrean.
create table public.rc_child (id int primary key, parent_id int not null references public.rc_part);
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  '{"table":"public.rc_child","op":"upsert","resync":true,"key":{"id":1},"row":{"id":1,"parent_id":99}}'::jsonb))) $$,
  'O1-C3: anak yatim dari resync tidak menahan antrean');
select ok(exists (select 1 from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_cx2)
                  and payload -> 'events' @> '[{"reason":"orphan","table":"public.rc_child","key":{"id":1}}]'), 'O1-C3: dilaporkan');
select throws_ok($$ select api.bus_receive('creator', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  '{"table":"public.rc_child","op":"upsert","key":{"id":2},"row":{"id":2,"parent_id":99}}'::jsonb))) $$, '23503', null,
  'O1-C3: kiriman biasa dengan induk belum tiba tetap menahan antrean');
insert into public.rc_child values (3, 1);
select lives_ok($$ select api.bus_receive('creator', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  '{"table":"public.rc_child","op":"upsert","resync":true,"key":{"id":3},"row":{"id":3,"parent_id":99}}'::jsonb))) $$,
  'O2-1: update resync ke induk yang hilang tidak menahan antrean');
select ok((select parent_id from public.rc_child where id = 3) = 1
          and exists (select 1 from ops.alerts where kind = 'bus.rejected_payload' and id > (select m from t_cx2)
                      and payload -> 'events' @> '[{"reason":"orphan","table":"public.rc_child","key":{"id":3}}]'),
          'O2-1: baris tidak berubah, dilaporkan');
drop table public.rc_src, public.rc_dst, public.rc_mixed, public.rc_ref, public.rc_child, public.rc_part;

-- Review CX16: bus.resync mengirim baris urut kunci primer (bukan urutan fisik heap) — penerima seperti apply_snapshot memproses
-- berurutan. Baris 1 di-update → pindah ke akhir heap → scan tanpa ORDER BY mengirim 2,3,1.
create table public.rs_order (id int primary key, a text);
create trigger rs_order_replicate after insert or update or delete on public.rs_order for each row execute function bus.replicate('creator:a');
insert into public.rs_order values (1, 'x'), (2, 'x'), (3, 'x');
update public.rs_order set a = 'y' where id = 1;
delete from bus.outbox where payload ->> 'table' = 'public.rs_order';
select bus.resync('public.rs_order', 'creator');
select is((select array_agg((payload -> 'key' ->> 'id')::int order by seq) from bus.outbox where payload ->> 'table' = 'public.rs_order'),
          array[1, 2, 3], 'CX16: resync mengirim urut kunci primer');
select ok((select bool_and((payload ->> 'resync')::boolean) from bus.outbox where payload ->> 'table' = 'public.rs_order'),
          'O1-C3: kiriman resync ditandai (penerima melaporkan anak yatim, bukan menahan antrean)');
delete from bus.outbox where payload ->> 'table' = 'public.rs_order';
drop table public.rs_order;

-- penerima: tabel replika dengan kolom milik project lain (b) tidak tersentuh upsert parsial; tanpa gema balik
create table public.rep_dst (id int primary key, a text, b text not null default 'lokal');
create trigger rep_dst_replicate after insert or update or delete on public.rep_dst for each row execute function bus.replicate('brand:b');
create table public.rep_hook_log (op text, row jsonb);
create function bus_in.public_rep_dst_applied(p_op text, p_row jsonb) returns void language sql as $$ insert into public.rep_hook_log values (p_op, p_row) $$;
delete from bus.outbox where target = 'brand';
select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c1","topic":"rep.row","payload":{"op":"upsert","key":{"id":7},"row":{"id":7,"a":"dari-pemilik"},"table":"public.rep_dst"}}]');
update public.rep_dst set b = 'milik-lokal' where id = 7;
select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c2","topic":"rep.row","payload":{"op":"upsert","key":{"id":7},"row":{"id":7,"a":"pemilik-ubah"},"table":"public.rep_dst"}}]');
select is((select a || '|' || b from public.rep_dst where id = 7), 'pemilik-ubah|milik-lokal',
          'upsert replika hanya kolom yang dikirim; kolom milik lokal tetap');
select is((select count(*)::int from bus.outbox where target = 'brand'), 1,
          'perubahan hasil replika tidak dipantulkan (hanya update kolom lokal b yang dikirim)');
select is((select array_agg(op order by row ->> 'a') from public.rep_hook_log), array['upsert', 'upsert'], 'hook penerima dijalankan per baris');
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c3","topic":"rep.row","payload":{"op":"delete","key":{"id":7},"row":null,"table":"public.rep_dst"}}]') $$,
                'delete baris campuran (kolom b milik lokal) tidak menahan antrean');
select ok(exists (select 1 from public.rep_dst where id = 7), 'R91-1: baris campuran tidak dihapus (dilewati)');
select is(current_setting('bus.applying', true), 'off', 'flag penerapan dimatikan lagi setelah apply');

-- kolom milik sebagian (pemilik baris project lain): baris ada → update kolom itu saja; baris belum ada → dilewati tanpa error
create table public.rep_part (id int primary key, owner_col text not null, status text not null default 'draft');
insert into public.rep_part values (1, 'milik-pemilik-baris', 'draft');
select lives_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c4","topic":"rep.row","payload":{"table":"public.rep_part","op":"upsert","key":{"id":1},"row":{"id":1,"status":"live"}}},
                                                        {"id":"00000000-0000-0000-0000-0000000000c5","topic":"rep.row","payload":{"table":"public.rep_part","op":"upsert","key":{"id":2},"row":{"id":2,"status":"live"}}}]') $$,
                'replika kolom parsial diterima (regresi: INSERT … ON CONFLICT menolak NOT NULL kolom lain)');
select is((select string_agg(id || ':' || owner_col || ':' || status, ',') from public.rep_part), '1:milik-pemilik-baris:live',
          'baris ada: hanya kolom terkirim yang berubah; baris belum ada: dilewati');

-- backfill: bus.resync mengirim ulang semua baris tabel pemilik dengan kolom dari trigger replicate-nya
delete from bus.outbox where target = 'creator';
insert into public.rep_src (id, a) values (11, 'x'), (12, 'y');
delete from bus.outbox where target = 'creator';
select is(bus.resync('public.rep_src', 'creator'), 2, 'resync: semua baris');
select is((select jsonb_agg(payload -> 'row' order by seq) from bus.outbox where target = 'creator'),
          '[{"a":"x","id":11},{"a":"y","id":12}]'::jsonb, 'resync memakai kolom trigger (tanpa kolom milik lain)');
select throws_ok($$ select bus.resync('public.rep_src', 'brand') $$, 'P0001', 'bus_no_replica:public.rep_src:brand',
                 'target tanpa replika ditolak');

select * from finish();
rollback;
