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
    if exists (select 1 from bus.inbox i where i.id = (e ->> 'id')::uuid) then
      skipped := skipped + 1;
      continue;
    end if;
    h := case when e ->> 'topic' = 'rep.row' then 'bus.apply_row(jsonb)'::regprocedure  -- replikasi baris: handler bawaan
              else to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_'))) end;
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc) using e -> 'payload';
    insert into bus.inbox (id, source, topic) values ((e ->> 'id')::uuid, p_source, e ->> 'topic');
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $$;

-- Antrean yang macet (dipantau admin): batch tertua tiap target yang sudah gagal ≥ 5 kali.
create function bus.stuck() returns table (target text, seq bigint, topic text, attempts int, last_error text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select distinct on (o.target) o.target, o.seq, o.topic, o.attempts, o.last_error, o.created_at
    from bus.outbox o where o.sent_at is null and o.attempts >= 5 order by o.target, o.seq;
$$;

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

create function bus.apply_row(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t regclass := (p ->> 'table')::regclass;
  pk text[] := bus.pk_columns(t);
  cols text[];
  upd text;
  h regprocedure;
begin
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = excluded.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do %4$s',
                   t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                   (select string_agg(format('%I', c), ', ') from unnest(pk) c),
                   case when upd is null then 'nothing' else 'update set ' || upd end)
      using p -> 'row';
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $$;

revoke all on bus.outbox, bus.inbox from anon, authenticated;
revoke execute on function bus.emit(text, text, jsonb), bus.relay(), bus.stuck(), api.bus_receive(text, jsonb), bus.pk_columns(regclass),
  bus.replicate(), bus.apply_row(jsonb) from public;
grant execute on function api.bus_receive(text, jsonb) to service_role;
