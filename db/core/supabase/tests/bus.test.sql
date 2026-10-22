-- Bus antar database (schemas/bus/bus.sql): outbox, relay (pg_net + HMAC), penerima idempoten.
begin;
select no_plan();

create function public.bus_test_handler(p jsonb) returns void language plpgsql as $$
begin
  insert into public.bus_test_log (v) values (p ->> 'v');
end $$;
create table public.bus_test_log (v text);
insert into bus.handlers (topic, fn) values ('test.ping', 'public.bus_test_handler(jsonb)');

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

select * from finish();
rollback;
