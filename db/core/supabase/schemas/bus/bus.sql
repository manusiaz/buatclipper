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
-- Kunci pemilik yang sedang direkonsiliasi (bus.reconcile → rep.keys, dikirim berpotongan): ditampung sampai potongan terakhir.
create table bus.reconcile_keys (
  source text not null,
  tbl text not null,
  epoch uuid not null,
  key jsonb not null,
  created_at timestamptz not null default now(),
  primary key (source, tbl, epoch, key)
);
alter table bus.reconcile_keys enable row level security;  -- policy:core.definer-only
-- Daftar kunci lengkap yang menunggu dihapus di sini (bus.reconcile_apply, job bus-reconcile): penghapusan tidak di dalam
-- bus_receive — tabel besar / banyak penolakan melewati statement_timeout bridge dan menahan antrean (O3-C1).
create table bus.reconcile_runs (
  source text not null,
  tbl text not null,
  epoch uuid not null,
  total bigint not null,
  created_at timestamptz not null default now(),
  primary key (source, tbl, epoch)
);
alter table bus.reconcile_runs enable row level security;  -- policy:core.definer-only

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
  head_tries int;
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
    select o.next_at <= now(), o.attempts into first_ready, head_tries
      from bus.outbox o where o.target = t and o.sent_at is null order by o.seq limit 1;
    continue when not coalesce(first_ready, false);
    select array_agg(b.seq order by b.seq), jsonb_agg(jsonb_build_object('id', b.id, 'topic', b.topic, 'payload', b.payload) order by b.seq)
      into ids, events
      from (select o.seq, o.id, o.topic, o.payload from bus.outbox o
             where o.target = t and o.sent_at is null order by o.seq
             -- gagal ≥ 3 kali → satu per satu: error penerima tidak menyebut event mana, jadi kepala = event yang gagal
             -- (bus.skip tepat sasaran, O1-C6)
             limit case when head_tries >= 3 then 1 else 100 end) b;
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
  -- rekonsiliasi yang terputus (potongan terakhir tak tiba); daftar lengkap yang masih diproses bus.reconcile_apply tidak disentuh
  delete from bus.reconcile_keys k where k.created_at < now() - interval '7 days'
     and not exists (select 1 from bus.reconcile_runs r where r.source = k.source and r.tbl = k.tbl and r.epoch = k.epoch);
$$;
revoke execute on function bus.prune() from public;

-- Replika ke tabel/kolom yang ADA di sini tapi bukan milik pengirim (kontrak dipensiunkan/pindah pemilik yang masih antre, atau
-- secret bocor) dilewati — tidak menahan antrean; yang BELUM ada di sini (penerima belum upgrade) dan topik perintah di luar
-- allowlist tetap raise (antrean ditahan, tidak ada yang hilang). Penolakan dikumpulkan per batch (bus.report_rejects): satu
-- laporan per kiriman, bukan satu per event. Di admin langsung alert; di creator/brand dikirim ke admin (topik bus.rejected).
-- Simpan 10 detail pertama + jumlah: ribuan penolakan (rekonsiliasi) tidak menyusun ulang jsonb yang terus membesar (O3-C1).
create function bus.reject(p_detail jsonb) returns void
language sql security definer set search_path = '' as $$
  select set_config('bus.rejects', case when jsonb_array_length(r) < 10 then r || jsonb_build_array(p_detail) else r end::text, true),
         set_config('bus.rejects_n', (coalesce(nullif(current_setting('bus.rejects_n', true), ''), '0')::int + 1)::text, true)
    from (select coalesce(nullif(current_setting('bus.rejects', true), ''), '[]')::jsonb r) x;
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
  d := jsonb_build_object('source', p_source, 'count', current_setting('bus.rejects_n', true)::int, 'events', r);
  perform set_config('bus.rejects', '', true);
  perform set_config('bus.rejects_n', '', true);
  if bus.me() = 'admin' then
    -- ops.raise_alert hanya ada di admin (fungsi ini dibagi ke creator/brand): dipanggil lewat regprocedure seperti handler bus_in
    execute format('select %s($1, $2, $3)', to_regprocedure('ops.raise_alert(text, text, jsonb, interval)')::regproc)
      using 'bus.rejected_payload', 'critical', d;
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
    if e ->> 'topic' = 'rep.keys' then  -- rekonsiliasi kunci (bus.reconcile): handler bawaan, allowlist yang sama
      perform bus.apply_keys(e -> 'payload', p_source);
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
-- Relay hanya melihat baris yang sudah commit dan created_at event = awal transaksinya, jadi at = waktu ping atau awal transaksi
-- lain di DB ini yang masih terbuka (mana yang lebih dulu): transaksi yang mulai sebelum at sudah selesai → event-nya (seq lebih
-- kecil) terkirim lebih dulu. Tidak menunggu — ping selalu terkirim (tanda hidup, seen_at di admin). Fail-closed → at = -infinity,
-- watermark tidak maju: sesi yang tidak terbaca (pemilik fungsi tanpa pg_read_all_stats → state NULL) atau transaksi prepared
-- (waktu prepared = saat PREPARE, bukan awal transaksi — bukan batas bawah created_at event-nya). Penulis outbox =
-- client backend (PostgREST, Edge Function, pg_cron lewat libpq: cron.use_background_workers off). Transaksi terbuka > 5 menit /
-- sesi tak terbaca dilaporkan di stuck (target 'transaksi') → alert bus.watermark_held di admin.
create function bus.ping() returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  t0 timestamptz := clock_timestamp();  -- sebelum membaca pg_stat_activity: transaksi yang mulai sesudahnya tidak diklaim
  h record;
  blind boolean;
  oldest timestamptz;
begin
  select exists (select 1 from pg_stat_activity a where a.datname = current_database() and a.backend_type = 'client backend'
                                                    and a.state is null and a.pid <> pg_backend_pid())
      or exists (select 1 from pg_prepared_xacts x where x.database = current_database()) into blind;
  select a.pid, a.xact_start, a.state into h from pg_stat_activity a
   where a.datname = current_database() and a.backend_type = 'client backend' and a.xact_start is not null
     and a.pid <> pg_backend_pid()
   order by a.xact_start limit 1;
  oldest := h.xact_start;
  return bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(),
    'at', case when blind then '-infinity'::timestamptz else least(t0, oldest) end,
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')
             || case when blind then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'reason', 'sesi tak terbaca / transaksi prepared'))
                     when oldest < t0 - interval '5 minutes'
                     then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'since', oldest, 'pid', h.pid, 'state', h.state))
                     else '[]' end));
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
-- Alat ops (deploy.sh bus skip): lewati baris kepala antrean ke satu target yang macet permanen (mis. topik yang dipensiunkan,
-- payload rusak). Event itu HILANG untuk penerima — pulihkan state replika dengan bus.resync sesudahnya. seq wajib = kepala antrean
-- (salah ketik tidak melewati event lain); isi event dikembalikan untuk dicatat operator.
create function bus.skip(p_target text, p_seq bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o bus.outbox;
begin
  select * into o from bus.outbox x where x.target = p_target and x.sent_at is null order by x.seq limit 1 for update;
  if not found or o.seq <> p_seq then
    raise exception 'bus_skip:bukan kepala antrean % (kepala: %)', p_target, o.seq using errcode = 'P0001';
  end if;
  update bus.outbox set sent_at = now(), request_id = null, last_error = 'dilewati operator ' || now() || ': ' || coalesce(last_error, '')
   where seq = o.seq;
  return jsonb_build_object('seq', o.seq, 'topic', o.topic, 'payload', o.payload, 'attempts', o.attempts, 'last_error', o.last_error);
end $$;
revoke execute on function bus.ping(), api.health(), bus.skip(text, bigint) from public;
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
  -- Rekonsiliasi tertunda (job bus-reconcile) untuk tabel ini: baris yang tiba sesudah daftar kunci (FIFO) ada di pemilik →
  -- masuk daftar supaya tidak ikut terhapus (O4-1).
  if p ->> 'op' = 'upsert' then
    insert into bus.reconcile_keys (source, tbl, epoch, key)
    select p_source, t::text, x.epoch, p -> 'key' from bus.reconcile_runs x where x.source = p_source and x.tbl = t::text
    on conflict do nothing;
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
    begin
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
      end if;
    exception when foreign_key_violation then
      -- Kiriman biasa: induk dari pengirim lain belum tiba → tahan antrean (dicoba lagi). Resync sesudah restore: induknya
      -- hilang bersama DB yang dipulihkan (mis. claim di admin untuk submisi creator, kategori baru untuk campaign lama) →
      -- dilaporkan, antrean jalan (O1-C3, O2-1: insert maupun update).
      if not coalesce((p ->> 'resync')::boolean, false) then
        raise;
      end if;
      perform bus.reject(jsonb_build_object('reason', 'orphan', 'table', p ->> 'table', 'key', p -> 'key', 'error', sqlerrm));
      n := 0;
    end;
    if n = 0 then
      perform set_config('bus.applying', 'off', true);
      return;
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
  -- urut kunci primer: penerima memproses berurutan (mis. snapshot — apply_snapshot menganggap id ≤ penanda sudah diproses, CX16)
  for r in execute format('select to_jsonb(t) from %s t order by %s', p_table,
                          (select string_agg(format('t.%I', k), ', ') from unnest(pk) k)) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert', 'resync', true,
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Restore satu DB (CX2/CL3): backup lama menghidupkan lagi baris replika yang sudah dihapus pemiliknya (mis. anggota org yang
-- dicabut → masih diberi akses di admin) dan resync hanya upsert. Pemilik mengirim SELURUH kunci tabelnya (snapshot di bawah lock
-- share, seperti resync — tulisan sesudahnya menyusul di belakang lewat FIFO), berpotongan 1000; penerima menghapus baris yang tidak
-- ada di daftar lewat apply_row delete (hook jalan; tabel campuran tidak dihapus tapi dilaporkan bus.reject). deploy.sh bus reconcile.
create function bus.reconcile(p_table regclass, p_target text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  pk text[] := bus.pk_columns(p_table);
  ep uuid := gen_random_uuid();
  keys jsonb := '[]';
  r jsonb;
  n int := 0;
begin
  if not exists (select 1 from pg_trigger tg
                  cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
                  where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target) then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  execute format('lock table %s in share mode', p_table);
  for r in execute format('select jsonb_build_object(%s) from %s t order by %s',
                          (select string_agg(format('%L, t.%I', k, k), ', ') from unnest(pk) k), p_table,
                          (select string_agg(format('t.%I', k), ', ') from unnest(pk) k)) loop
    keys := keys || jsonb_build_array(r);
    n := n + 1;
    if jsonb_array_length(keys) = 1000 then
      perform bus.emit(p_target, 'rep.keys', jsonb_build_object('table', p_table::text, 'epoch', ep, 'keys', keys, 'last', false));
      keys := '[]';
    end if;
  end loop;
  perform bus.emit(p_target, 'rep.keys', jsonb_build_object('table', p_table::text, 'epoch', ep, 'keys', keys, 'last', true, 'total', n));
  return n;
end $$;

create function bus.apply_keys(p jsonb, p_source text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t regclass := to_regclass(p ->> 'table');
begin
  if t is null then  -- penerima belum upgrade: tahan antrean (sama dengan apply_row)
    raise exception 'bus_no_table:%', p ->> 'table' using errcode = 'P0001';
  end if;
  if bus.accepts(p_source, p ->> 'table') is null then  -- bukan tabel yang direplikasi pengirim ke sini
    perform bus.reject(jsonb_build_object('reason', 'table', 'table', p ->> 'table', 'op', 'reconcile'));
    return;
  end if;
  insert into bus.reconcile_keys (source, tbl, epoch, key)
  select p_source, t::text, (p ->> 'epoch')::uuid, x from jsonb_array_elements(coalesce(p -> 'keys', '[]')) x
  on conflict do nothing;
  if not coalesce((p ->> 'last')::boolean, false) then
    return;
  end if;
  -- Daftar tidak lengkap (potongan dipangkas bus.prune saat antrean macet > 7 hari, atau dilewati bus.skip) → tidak ada yang
  -- dihapus; dilaporkan, jalankan reconcile ulang (O1-3).
  if (select count(*) from bus.reconcile_keys r where r.source = p_source and r.tbl = t::text and r.epoch = (p ->> 'epoch')::uuid)
     is distinct from (p ->> 'total')::bigint then
    perform bus.reject(jsonb_build_object('reason', 'reconcile_incomplete', 'table', t::text, 'total', p -> 'total'));
    delete from bus.reconcile_keys where source = p_source and tbl = t::text and epoch = (p ->> 'epoch')::uuid;
    return;
  end if;
  insert into bus.reconcile_runs (source, tbl, epoch, total) values (p_source, t::text, (p ->> 'epoch')::uuid, (p ->> 'total')::bigint)
  on conflict do nothing;
end $$;

-- Job bus-reconcile: baris replika yang tidak ada di daftar kunci lengkap pemilik dihapus lewat apply_row delete (hook jalan),
-- paling banyak p_limit baris per panggilan. Baris yang tidak boleh dihapus (append-only, dirujuk) dilaporkan reconcile_delete,
-- baris campuran dilaporkan apply_row ('delete'); keduanya dicatat ke daftar supaya putaran berikut tidak mengulanginya.
create function bus.reconcile_apply(p_limit int default 5000) returns int
language plpgsql security definer set search_path = '' as $$
declare
  r bus.reconcile_runs;
  t regclass;
  k jsonb;
  pk text[];
  n int := 0;
  budget int;
  m int;
begin
  for r in select * from bus.reconcile_runs x order by x.created_at loop
    budget := p_limit - n;
    exit when budget <= 0;
    t := to_regclass(r.tbl);
    m := 0;
    if t is not null then
      pk := bus.pk_columns(t);
      for k in execute format('select jsonb_build_object(%s) from %s x where not exists (select 1 from bus.reconcile_keys r
                                 where r.source = $1 and r.tbl = $2 and r.epoch = $3 and r.key = jsonb_build_object(%1$s)) limit $4',
                              (select string_agg(format('%L, x.%I', c, c), ', ') from unnest(pk) c), t)
                 using r.source, r.tbl, r.epoch, budget loop
        begin
          perform bus.apply_row(jsonb_build_object('table', r.tbl, 'op', 'delete', 'key', k), r.source);
        exception when others then
          perform bus.reject(jsonb_build_object('reason', 'reconcile_delete', 'table', r.tbl, 'key', k, 'error', sqlerrm));
        end;
        insert into bus.reconcile_keys (source, tbl, epoch, key) values (r.source, r.tbl, r.epoch, k) on conflict do nothing;
        m := m + 1;
      end loop;
    end if;
    n := n + m;
    if m < budget then  -- tidak ada lagi yang tersisa: selesai
      delete from bus.reconcile_keys x where x.source = r.source and x.tbl = r.tbl and x.epoch = r.epoch;
      delete from bus.reconcile_runs x where x.source = r.source and x.tbl = r.tbl and x.epoch = r.epoch;
    end if;
    perform bus.report_rejects(r.source);
  end loop;
  return n;
end $$;

-- Tabel milik project ini yang direplikasi ke satu target (trigger bus.replicate) — daftar untuk deploy.sh bus reconcile, urut FK:
-- induk dulu (kedalaman referensi ke tabel lain di daftar). Resync memakai urutan ini (anak tidak menunjuk induk yang belum ada di
-- penerima), reconcile urutan terbalik (anak dihapus sebelum induknya).
create function bus.replica_tables(p_target text) returns setof regclass
language sql stable security definer set search_path = '' as $$
  with recursive t as (
    select distinct tg.tgrelid as r from pg_trigger tg
     cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
     where tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target
  ), d (r, depth) as (
    select r, 0 from t
    union all
    select c.conrelid, d.depth + 1 from d
      join pg_constraint c on c.confrelid = d.r and c.contype = 'f' and c.conrelid <> c.confrelid and c.conrelid in (select r from t)
     where d.depth < 20
  )
  select r::regclass from d group by r order by max(depth), r::regclass::text;
$$;

revoke all on bus.outbox, bus.inbox, bus.reconcile_keys, bus.reconcile_runs from anon, authenticated;
revoke execute on function bus.reject(jsonb), bus.report_rejects(text) from public;
revoke execute on function bus.emit(text, text, jsonb), bus.relay(), bus.stuck(), api.bus_receive(text, jsonb), bus.pk_columns(regclass),
  bus.replicate(), bus.apply_row(jsonb, text), bus.resync(regclass, text), bus.reconcile(regclass, text), bus.apply_keys(jsonb, text), bus.reconcile_apply(int),
  bus.replica_tables(text) from public;
grant execute on function api.bus_receive(text, jsonb) to service_role;
