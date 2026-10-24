-- Bus antar database (schemas/bus/bus.sql): outbox, relay (pg_net + HMAC), penerima idempoten.
begin;
select no_plan();

-- allowlist bus (bus/accept.sql) + topik & tabel uji file ini (di-rollback bersama tes)
alter function bus.accepts(text, text) rename to accepts_real;
create function bus.accepts(p_source text, p_table text) returns text[] language sql as $$
  select case p_table when 'public.rep_dst' then array['a'] when 'public.rep_part' then array['status'] else bus.accepts_real(p_source, p_table) end;
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

-- Review Claude C3: pengirim hanya bisa menulis tabel & kolom yang memang direplikasi pemiliknya ke sini
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e1","topic":"rep.row","payload":{"op":"upsert","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":{"id":"11111111-0000-0000-0000-00000000000a","status":"active","trust_score":100},"table":"market.profiles"}}]') $$,
                 '42501', 'bus_not_allowed:creator market.profiles', 'C3: creator tidak bisa menulis kolom milik admin (status/trust profil)');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e2","topic":"rep.row","payload":{"op":"upsert","key":{"id":"00000000-0000-0000-0000-0000000000e2"},"row":{"id":"00000000-0000-0000-0000-0000000000e2","value":"1"},"table":"ops.settings"}}]') $$,
                 '42501', 'bus_not_allowed:creator ops.settings', 'C3: tabel yang tidak direplikasi pengirim ke sini ditolak');
select throws_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e3","topic":"rep.row","payload":{"op":"delete","key":{"id":"11111111-0000-0000-0000-00000000000a"},"row":null,"table":"market.profiles"}}]') $$,
                 '42501', 'bus_not_allowed:brand market.profiles', 'C3: delete juga dibatasi allowlist pengirim');
select ok(not exists (select 1 from bus.inbox where id in ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2',
                                                           '00000000-0000-0000-0000-0000000000e3')), 'event yang ditolak tidak tercatat diterima');
-- Review C5/R88-1: topik hanya dari pengirim yang memang mengirimnya; sumber ping = pengirim terautentikasi
select throws_ok($$ select api.bus_receive('brand', '[{"id":"00000000-0000-0000-0000-0000000000e4","topic":"submission.post_gone","payload":{"submission_id":"00000000-0000-0000-0000-0000000000e4"}}]') $$,
                 '42501', 'bus_not_allowed:brand submission.post_gone', 'C5: brand tidak bisa memanggil handler milik creator (post_gone)');
select throws_ok($$ select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000e5","topic":"org.owner_lost","payload":{}}]') $$,
                 '42501', 'bus_not_allowed:creator org.owner_lost', 'C5: creator tidak bisa memanggil handler milik brand');
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
select is((select count(*)::int from ops.alerts where kind = 'bus.rejected_payload'), 2, 'C7: payload yang dilewati → alert');

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
select api.bus_receive('creator', '[{"id":"00000000-0000-0000-0000-0000000000c3","topic":"rep.row","payload":{"op":"delete","key":{"id":7},"row":null,"table":"public.rep_dst"}}]');
select ok(not exists (select 1 from public.rep_dst where id = 7), 'delete replika');
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
