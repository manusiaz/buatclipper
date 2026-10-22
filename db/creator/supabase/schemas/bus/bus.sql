-- Bus event antar database (arsitektur 4 DB). File ini identik di semua project; nama project sendiri di bus/self.sql.
--   kirim : bus.emit(target, topic, payload) di transaksi yang sama dengan datanya (transactional outbox)
--   relay : job bus-relay (pg_cron, tiap 5 detik) → satu batch per target, urut seq, ditandatangani HMAC
--           → POST {bus_url_<target>}/functions/v1/bridge action 'bus.deliver' (protokol bridge, header x-bridge-from)
--   terima: api.bus_receive(source, events) satu transaksi per batch; event yang sudah ada di bus.inbox dilewati (idempoten),
--           handler per topic dari bus.handlers. Gagal → seluruh batch ditolak, pengirim mengulang dengan backoff;
--           batch berikutnya tidak dikirim sebelum batch ini diterima (urutan per target terjaga).
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

-- topic → fungsi handler(jsonb) returns void, diisi file domain yang menerima event itu.
create table bus.handlers (
  topic text primary key,
  fn regprocedure not null
);

alter table bus.outbox enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)
alter table bus.inbox enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)
alter table bus.handlers enable row level security;  -- policy:core.definer-only (tanpa policy: hanya fungsi definer)

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
    select bh.fn into h from bus.handlers bh where bh.topic = e ->> 'topic';
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

revoke all on bus.outbox, bus.inbox, bus.handlers from anon, authenticated;
revoke execute on function bus.emit(text, text, jsonb), bus.relay(), bus.stuck(), api.bus_receive(text, jsonb) from public;
grant execute on function api.bus_receive(text, jsonb) to service_role;
