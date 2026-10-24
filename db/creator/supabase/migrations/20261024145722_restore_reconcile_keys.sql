SET local check_function_bodies = off;

CREATE TABLE "bus"."reconcile_keys" (
  "source"     text                     NOT NULL,
  "tbl"        text                     NOT NULL,
  "epoch"      uuid                     NOT NULL,
  "key"        jsonb                    NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "reconcile_keys_pkey" PRIMARY KEY (source, tbl, epoch, key)
);

ALTER TABLE "bus"."reconcile_keys"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION api.bus_receive (
  p_source text,
  p_events jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_keys (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t regclass := to_regclass(p ->> 'table');
  pk text[];
  k jsonb;
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
  pk := bus.pk_columns(t);
  for k in execute format('select jsonb_build_object(%s) from %s x where not exists (select 1 from bus.reconcile_keys r
                             where r.source = $1 and r.tbl = $2 and r.epoch = $3 and r.key = jsonb_build_object(%1$s))',
                          (select string_agg(format('%L, x.%I', c, c), ', ') from unnest(pk) c), t)
             using p_source, t::text, (p ->> 'epoch')::uuid loop
    perform bus.apply_row(jsonb_build_object('table', t::text, 'op', 'delete', 'key', k), p_source);
  end loop;
  delete from bus.reconcile_keys where source = p_source and tbl = t::text and epoch = (p ->> 'epoch')::uuid;
end $function$;

CREATE OR REPLACE FUNCTION bus.prune()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  delete from bus.outbox where sent_at < now() - interval '14 days';
  delete from bus.reconcile_keys where created_at < now() - interval '7 days';  -- rekonsiliasi yang terputus (potongan terakhir tak tiba)
$function$;

CREATE OR REPLACE FUNCTION bus.reconcile (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  perform bus.emit(p_target, 'rep.keys', jsonb_build_object('table', p_table::text, 'epoch', ep, 'keys', keys, 'last', true));
  return n;
end $function$;

CREATE OR REPLACE FUNCTION bus.replica_tables (
  p_target text
)
  RETURNS SETOF regclass
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select distinct tg.tgrelid::regclass from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target
   order by 1;
$function$;

REVOKE ALL ON FUNCTION "bus"."apply_keys"(jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."apply_keys"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."apply_keys"(jsonb, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."reconcile"(regclass, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."reconcile"(regclass, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."reconcile"(regclass, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."replica_tables"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."replica_tables"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."replica_tables"(text) TO "postgres";
