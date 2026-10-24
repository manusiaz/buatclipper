-- Bus event antar database (arsitektur 4 DB). File ini identik di semua project; nama project sendiri di bus/self.sql.
--   kirim : bus.emit(target, topic, payload) di transaksi yang sama dengan datanya (transactional outbox)
--   relay : job bus-relay (pg_cron, tiap 5 detik) → satu batch per target, urut seq, ditandatangani HMAC
--           → POST {bus_url_<target>}/functions/v1/bridge action 'bus.deliver' (protokol bridge, header x-bridge-from)
--   terima: api.bus_receive(source, events) satu transaksi per batch; event yang sudah ada di bus.inbox dilewati (idempoten),
--           handler per topic (konvensi nama bus_in.*). Gagal → seluruh batch ditolak, pengirim mengulang dengan backoff;
--           batch berikutnya tidak dikirim sebelum batch ini diterima (urutan per target terjaga).
--   handler: fungsi bus_in.<topic dengan titik → garis bawah>(payload jsonb), mis. topic 'audit.log' → bus_in.audit_log(jsonb).
--           Konvensi nama (bukan tabel konfigurasi) supaya pendaftaran ikut DDL/migrasi.
-- Vault pengirim: bus_url_<target> (URL dasar Kong target) dan bus_secret_<target> (secret HMAC pengirim → target).
create schema if not exists bus;

create table bus.outbox (
  seq bigint generated always as identity primary key,
  id uuid not null default gen_random_uuid() unique,
  target text not null check (target in ('identity', 'creator', 'brand', 'admin')),
  topic text not null check (topic ~ '^[a-z][a-z_]*(\.[a-z][a-z_]*)+$'),
  payload jsonb not null,
  created_at timestamptz not null default now(),
  request_id bigint,
  requested_at timestamptz,
  sent_at timestamptz,
  attempts int not null default 0,
  next_at timestamptz not null default now(),
  last_error text
);
create index outbox_pending_idx on bus.outbox (target, seq) where sent_at is null;

create table bus.inbox (
  id uuid primary key,
  source text not null,
  topic text not null,
  received_at timestamptz not null default now()
);

create schema if not exists bus_in;  -- handler event masuk (lihat kepala file)

alter table bus.outbox enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)
alter table bus.inbox enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)

create function bus.emit(p_target text, p_topic text, p_payload jsonb) returns uuid
language sql security definer set search_path = '' as $$
  insert into bus.outbox (target, topic, payload) values (p_target, p_topic, p_payload) returning id;
$$;

-- Satu putaran relay. Batch yang sedang dikirim dicek lewat net._http_response: 200 = diterima; lainnya / tidak ada jawaban
-- > 60 detik = gagal → backoff (5 dtk × 2^attempts, maks 1 jam). Batch baru hanya dikirim bila baris tertua target siap.
create function bus.relay() returns int
language plpgsql security definer set search_path = '' as $$
declare
  t text;
  rid bigint;
  asked timestamptz;
  resp record;
  first_ready boolean;
  ids bigint[];
  events jsonb;
  body jsonb;
  ts text;
  url text;
  secret text;
  sent int := 0;
begin
  for t in select distinct o.target from bus.outbox o where o.sent_at is null order by 1 loop
    continue when not pg_try_advisory_xact_lock(hashtextextended('bus_relay:' || t, 0));
    select o.request_id, o.requested_at into rid, asked
      from bus.outbox o where o.target = t and o.sent_at is null and o.request_id is not null order by o.seq limit 1;
    if rid is not null then
      select r.status_code, r.timed_out, r.error_msg, left(r.content, 500) as content into resp
        from net._http_response r where r.id = rid;
      if found and resp.status_code = 200 then
        update bus.outbox set sent_at = now(), last_error = null where target = t and request_id = rid;
      elsif found or asked < now() - interval '60 seconds' then
        update bus.outbox
           set request_id = null, requested_at = null, attempts = attempts + 1,
               next_at = now() + least(interval '1 hour', interval '5 seconds' * power(2, least(attempts, 10))),
               last_error = coalesce(resp.error_msg, case when resp.timed_out then 'timeout' end,
                                     'http ' || resp.status_code || ' ' || coalesce(resp.content, ''), 'no response')
         where target = t and request_id = rid;
        continue;
      else
        continue;  -- masih menunggu jawaban
      end if;
    end if;
    select o.next_at <= now() into first_ready
      from bus.outbox o where o.target = t and o.sent_at is null order by o.seq limit 1;
    continue when not coalesce(first_ready, false);
    select array_agg(b.seq order by b.seq), jsonb_agg(jsonb_build_object('id', b.id, 'topic', b.topic, 'payload', b.payload) order by b.seq)
      into ids, events
      from (select o.seq, o.id, o.topic, o.payload from bus.outbox o
             where o.target = t and o.sent_at is null order by o.seq limit 100) b;
    select ds.decrypted_secret into url from vault.decrypted_secrets ds where ds.name = 'bus_url_' || t;
    select ds.decrypted_secret into secret from vault.decrypted_secrets ds where ds.name = 'bus_secret_' || t;
    if url is null or secret is null then
      update bus.outbox set last_error = 'vault bus_url_/bus_secret_' || t || ' belum diisi' where seq = any (ids);
      continue;
    end if;
    body := jsonb_build_object('v', 1, 'action', 'bus.deliver', 'payload', jsonb_build_object('source', bus.me(), 'events', events));
    ts := floor(extract(epoch from now()))::bigint::text;
    rid := net.http_post(
      url := url || '/functions/v1/bridge',
      body := body,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-bridge-ts', ts, 'x-bridge-from', bus.me(),
                                    'x-bridge-sig', encode(extensions.hmac(ts || '.' || body::text, secret, 'sha256'), 'hex')),
      timeout_milliseconds := 15000);
    update bus.outbox set request_id = rid, requested_at = now() where seq = any (ids);
    sent := sent + cardinality(ids);
  end loop;
  return sent;
end $$;

-- Dipanggil Edge Function bridge (service role) setelah HMAC sumber terverifikasi. Satu transaksi untuk seluruh batch.
-- Retensi (job bus-prune): outbox terkirim 14 hari — payload memuat data user (profil, caption), tidak disimpan selamanya
-- (UU PDP). Inbox (id, sumber, topik saja) TIDAK dipangkas: kiriman ulang batch yang ack-nya hilang bisa datang kapan pun
-- pengirim pulih, dan id inbox satu-satunya pencegah perintah diterapkan dua kali.
create function bus.prune() returns void
language sql security definer set search_path = '' as $$
  delete from bus.outbox where sent_at < now() - interval '14 days';
$$;
revoke execute on function bus.prune() from public;

-- Replika ke tabel/kolom yang ADA di sini tapi bukan milik pengirim (kontrak dipensiunkan/pindah pemilik yang masih antre, atau
-- secret bocor) dilewati — tidak menahan antrean; yang BELUM ada di sini (penerima belum upgrade) dan topik perintah di luar
-- allowlist tetap raise (antrean ditahan, tidak ada yang hilang). Penolakan dikumpulkan per batch (bus.report_rejects): satu
-- laporan per kiriman, bukan satu per event. Di admin langsung alert; di creator/brand dikirim ke admin (topik bus.rejected).
create function bus.reject(p_detail jsonb) returns void
language sql security definer set search_path = '' as $$
  select set_config('bus.rejects', (coalesce(nullif(current_setting('bus.rejects', true), ''), '[]')::jsonb
                                    || jsonb_build_array(p_detail))::text, true);
$$;

create function bus.report_rejects(p_source text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r jsonb := nullif(current_setting('bus.rejects', true), '')::jsonb;
  d jsonb;
begin
  if r is null then
    return;
  end if;
  perform set_config('bus.rejects', '', true);
  d := jsonb_build_object('source', p_source, 'count', jsonb_array_length(r),
                          'events', (select jsonb_agg(x) from (select x from jsonb_array_elements(r) x limit 10) f));
  if bus.me() = 'admin' then
    execute 'select ops.raise_alert($1, $2, $3)' using 'bus.rejected_payload', 'critical', d;
  else
    perform bus.emit('admin', 'bus.rejected', d);
  end if;
end $$;

create function api.bus_receive(p_source text, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e jsonb;
  h regprocedure;
  applied int := 0;
  skipped int := 0;
begin
  if jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'invalid:events' using errcode = 'P0001';
  end if;
  for e in select x from jsonb_array_elements(p_events) x loop
    -- klaim event dulu: kiriman kembar yang berjalan bersamaan (relay mengulang saat request pertama masih di DB) menunggu
    -- transaksi pertama lalu dilewati, bukan gagal duplicate key → 500 → backoff. Handler raise → klaim ikut batal.
    insert into bus.inbox (id, source, topic) values ((e ->> 'id')::uuid, p_source, e ->> 'topic') on conflict (id) do nothing;
    if not found then
      skipped := skipped + 1;
      continue;
    end if;
    if e ->> 'topic' = 'rep.row' then  -- replikasi baris: handler bawaan, dibatasi allowlist pengirim (bus.accepts)
      perform bus.apply_row(e -> 'payload', p_source);
      applied := applied + 1;
      continue;
    end if;
    -- Handler belum ada (penerima belum di-deploy) / pengirim tidak memanggil bus.emit-nya (bus.accepts_topic) → raise, antrean
    -- ditahan: perintah (mis. profile.anonymize) tidak boleh hilang, dan event yang ditolak tidak boleh sampai ke efek sesudah
    -- batch (hapus file Storage di bridge). uji.ping = handler e2e/bus.sh yang hanya ada selama uji berjalan.
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    if not bus.accepts_topic(p_source, e ->> 'topic') and e ->> 'topic' <> 'uji.ping' then
      raise exception 'bus_not_allowed:% %', p_source, e ->> 'topic' using errcode = '42501';
    end if;
    execute format('select %s($1)', h::regproc)  -- _source = pengirim terautentikasi (handler memvalidasi isi per pengirim)
      using e -> 'payload' || jsonb_build_object('_source', p_source);
    applied := applied + 1;
  end loop;
  perform bus.report_rejects(p_source);
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $$;

-- Antrean yang macet (dipantau admin): batch tertua tiap target yang sudah gagal ≥ 5 kali.
create function bus.stuck() returns table (target text, seq bigint, topic text, attempts int, last_error text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select distinct on (o.target) o.target, o.seq, o.topic, o.attempts, o.last_error, o.created_at
    from bus.outbox o where o.sent_at is null and o.attempts >= 5 order by o.target, o.seq;
$$;

-- ===== Pemantauan =====
-- bus.ping: creator/brand → admin tiap 5 menit (job bus-ping di bus/self.sql). Antrean per target FIFO, jadi ping yang telat =
-- antrean pengirim → admin macet; payload stuck = antrean pengirim ke target lain yang macet. Admin menyimpan & memberi alert.
create index inbox_source_idx on bus.inbox (source, received_at desc);

-- Ping = watermark di admin (lock tanpa snapshot final, settle R83-1): "semua event yang dibuat sebelum at sudah di depan ping".
-- Relay hanya melihat baris yang sudah commit, jadi ping baru dibuat setelah semua transaksi yang berjalan saat at selesai
-- (event-nya tertulis sebelum ping → seq lebih kecil → terkirim lebih dulu). Transaksi > 60 detik → ping dilewati (watermark
-- tidak maju; ping telat → bus.stuck).
create function bus.ping() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  at timestamptz := clock_timestamp();
  me bigint := pg_current_xact_id()::text::bigint;  -- diambil sesudah at: transaksi yang menulis sebelum at punya xid < me
  lo bigint := pg_snapshot_xmin(pg_current_snapshot())::text::bigint;
  x bigint;
begin
  -- xid yang masih berjalan bisa ≥ xmax snapshot (tidak tercantum di xip), jadi seluruh rentang [xmin, me) dicek
  if me - lo > 1000000 then
    return null;
  end if;
  for x in lo .. me - 1 loop
    while pg_xact_status(x::text::xid8) = 'in progress' loop
      if clock_timestamp() > at + interval '60 seconds' then
        return null;
      end if;
      perform pg_sleep(0.05);
    end loop;
  end loop;
  return bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(), 'at', at,
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')));
end $$;

-- Endpoint health tiap project (POST /rest/v1/rpc/health): antrean keluar per target + event terakhir yang diterima per sumber.
-- Angka & waktu saja (tanpa pesan error / URL), jadi boleh dipanggil monitor uptime dengan publishable key.
create function api.health() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('db', bus.me(), 'at', now(),
    'outbox', coalesce((select jsonb_object_agg(x.target, jsonb_build_object('pending', x.pending, 'stuck', x.stuck, 'oldest_pending_at', x.oldest))
                          from (select o.target, count(*) as pending, count(*) filter (where o.attempts >= 5) as stuck, min(o.created_at) as oldest
                                  from bus.outbox o where o.sent_at is null group by o.target) x), '{}'),
    'last_received', (select jsonb_object_agg(src, (select max(i.received_at) from bus.inbox i where i.source = src))
                        from unnest(array['creator', 'brand', 'admin']) src where src <> bus.me()));
$$;
revoke execute on function bus.ping(), api.health() from public;
grant execute on function api.health() to anon, authenticated, service_role;

-- ===== Replikasi baris (pemilik kolom → replika read-only di project lain) =====
-- Pemilik memasang trigger AFTER INSERT/UPDATE/DELETE ... execute function bus.replicate('<target>:<kolom>,<kolom>', ...):
-- tiap argumen = satu target + kolom milik project ini yang dikirim (primary key selalu ikut). Konfigurasi di argumen trigger
-- (DDL) supaya ikut migrasi. Topic 'rep.row' hanya dikirim bila kolom milik sendiri berubah.
-- Penerima: bus.apply_row upsert kolom yang dikirim saja (kolom milik project lain di baris yang sama tidak tersentuh) atau
-- delete; flag transaksi bus.applying = on selama penerapan supaya trigger bus.replicate di penerima tidak memantulkannya.
-- Urutan per baris aman: update baris yang sama terserialisasi row lock, jadi seq outbox = urutan commit baris itu.
-- Reaksi penerima (mis. accrual saat snapshot tiba): fungsi bus_in.<schema>_<tabel>_applied(op text, row jsonb) bila ada.
create function bus.pk_columns(p_table regclass) returns text[]
language sql stable set search_path = '' as $$
  select array_agg(a.attname::text order by k.ord)
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indrelid = p_table and i.indisprimary;
$$;

create function bus.replicate() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  newj jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  oldj jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  pk text[] := bus.pk_columns(tg_relid);
begin
  if current_setting('bus.applying', true) = 'on' then
    return null;
  end if;
  for r in select split_part(a, ':', 1) as target, string_to_array(split_part(a, ':', 2), ',') as columns
             from unnest(tg_argv) a loop
    continue when tg_op = 'UPDATE' and not exists (select 1 from unnest(r.columns) c where newj -> c is distinct from oldj -> c);
    perform bus.emit(r.target, 'rep.row', jsonb_build_object(
      'table', tg_relid::regclass::text,
      'op', case when tg_op = 'DELETE' then 'delete' else 'upsert' end,
      'key', (select jsonb_object_agg(k, coalesce(newj, oldj) -> k) from unnest(pk) k),
      'row', case when tg_op <> 'DELETE' then (select jsonb_object_agg(c, newj -> c) from unnest(r.columns || pk) c) end));
  end loop;
  return null;
end $$;

create function bus.apply_row(p jsonb, p_source text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := bus.accepts(p_source, p ->> 'table');
  bad text[];
  t regclass;
  pk text[];
  cols text[];
  upd text;
  n int := 0;
  h regprocedure;
begin
  -- Hanya tabel & kolom yang dikirim pemiliknya (bus/accept.sql, dari trigger bus.replicate pengirim): secret bus satu peer
  -- yang bocor tidak bisa menulis tabel lain di sini (uang, sanksi) atau kolom milik penerima.
  t := to_regclass(p ->> 'table');
  if t is null then  -- tabel belum ada di sini: penerima belum upgrade → tahan antrean
    raise exception 'bus_no_table:%', p ->> 'table' using errcode = 'P0001';
  end if;
  if allowed is null then
    perform bus.reject(jsonb_build_object('reason', 'table', 'table', p ->> 'table', 'op', p ->> 'op'));
    return;
  end if;
  pk := bus.pk_columns(t);
  bad := array(select k from jsonb_object_keys(case when jsonb_typeof(p -> 'row') = 'object' then p -> 'row' else '{}' end) k
                where not k = any (allowed || pk));
  -- kolom yang belum ada di sini (pengirim sudah upgrade, penerima belum) → tahan antrean, bukan dibuang
  if exists (select 1 from unnest(bad) k where not exists (select 1 from pg_attribute a where a.attrelid = t and a.attname = k
                                                                                        and a.attnum > 0 and not a.attisdropped)) then
    raise exception 'bus_no_column:% %', p ->> 'table', bad::text using errcode = 'P0001';
  end if;
  -- kolom yang ada tapi di luar allowlist (milik penerima / dipensiunkan) dibuang, sisanya tetap diterapkan
  if cardinality(bad) > 0 then
    perform bus.reject(jsonb_build_object('reason', 'columns', 'table', p ->> 'table', 'columns', to_jsonb(bad)));
    p := jsonb_set(p, '{row}', (p -> 'row') - bad);
  end if;
  -- delete hanya untuk tabel yang seluruh kolomnya milik pengirim: baris campuran (mis. profil dengan status/sanksi admin, org
  -- dengan fee admin) yang dihapus lalu dikirim ulang akan mengembalikan kolom milik penerima ke default. Dilewati + alert (tidak
  -- raise): delete baris campuran di pengirim (mis. hapus manual) tidak boleh menahan antrean selamanya.
  if p ->> 'op' = 'delete' and exists (select 1 from pg_attribute a where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                                                                    and not a.attname = any (allowed || pk)) then
    perform bus.reject(jsonb_build_object('reason', 'delete', 'table', p ->> 'table', 'key', p -> 'key'));
    return;
  end if;
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = r.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    -- update dulu: baris dengan kolom milik sebagian (mis. status dari admin) tidak bisa lewat INSERT … ON CONFLICT (NOT NULL
    -- kolom lain dicek sebelum konflik). Baris belum ada → insert; kolom wajib lain tidak dikirim = baris milik project lain
    -- yang belum/tidak ada di sini → dilewati. Nilai sama persis (bus.resync) → tidak diubah dan hook tidak jalan: tabel
    -- append-only menolak UPDATE dan hook (accrual, keputusan) tidak boleh jalan dua kali.
    if upd is not null then
      execute format('update %1$s x set %2$s from jsonb_populate_record(null::%1$s, $1) r where %3$s and row(%4$s) is distinct from row(%5$s)',
                     t, upd, (select string_agg(format('x.%1$I = r.%1$I', c), ' and ') from unnest(pk) c),
                     (select string_agg(format('x.%I', c), ', ') from unnest(cols) c),
                     (select string_agg(format('r.%I', c), ', ') from unnest(cols) c))
        using p -> 'row';
      get diagnostics n = row_count;
    end if;
    if n = 0 then
      begin
        execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do nothing',
                       t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                       (select string_agg(format('%I', c), ', ') from unnest(pk) c))
          using p -> 'row';
        get diagnostics n = row_count;
      exception when not_null_violation then
        n := 0;
      end;
      if n = 0 then
        perform set_config('bus.applying', 'off', true);
        return;
      end if;
    end if;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $$;

-- Backfill replika (tabel replika baru, data lama): kirim ulang semua baris tabel pemilik ke satu target memakai kolom dari
-- trigger bus.replicate tabel itu. Penerima upsert idempoten. Dipanggil operator (service role / psql).
create function bus.resync(p_table regclass, p_target text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  cols text[];
  pk text[] := bus.pk_columns(p_table);
  r jsonb;
  n int := 0;
begin
  select string_to_array(split_part(a, ':', 2), ',') into cols
    from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target;
  if cols is null then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  -- Tulisan baru menunggu sampai resync commit: event resync (snapshot lama) tidak bisa menyalip event tulisan yang lebih baru (R83-2).
  execute format('lock table %s in share mode', p_table);
  for r in execute format('select to_jsonb(t) from %s t', p_table) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert',
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on bus.outbox, bus.inbox from anon, authenticated;
revoke execute on function bus.reject(jsonb), bus.report_rejects(text) from public;
revoke execute on function bus.emit(text, text, jsonb), bus.relay(), bus.stuck(), api.bus_receive(text, jsonb), bus.pk_columns(regclass),
  bus.replicate(), bus.apply_row(jsonb, text), bus.resync(regclass, text) from public;
grant execute on function api.bus_receive(text, jsonb) to service_role;
