SET local check_function_bodies = off;

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
    -- Handler belum ada (penerima belum di-deploy) → tahan antrean sampai upgrade: perintah (mis. profile.anonymize) tidak boleh
    -- hilang. Handler ada tapi pengirim tidak memanggil bus.emit-nya (bus.accepts_topic) → dilewati + dilaporkan (bus.reject).
    -- uji.ping = handler e2e/bus.sh yang hanya ada selama uji berjalan.
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    if not bus.accepts_topic(p_source, e ->> 'topic') and e ->> 'topic' <> 'uji.ping' then
      perform bus.reject(jsonb_build_object('reason', 'topic', 'source', p_source, 'topic', e ->> 'topic'));
      skipped := skipped + 1;
      continue;
    end if;
    execute format('select %s($1)', h::regproc)  -- _source = pengirim terautentikasi (handler memvalidasi isi per pengirim)
      using e -> 'payload' || jsonb_build_object('_source', p_source);
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if allowed is null then
    perform bus.reject(jsonb_build_object('reason', 'table', 'source', p_source, 'table', p ->> 'table', 'op', p ->> 'op'));
    return;
  end if;
  t := (p ->> 'table')::regclass;
  pk := bus.pk_columns(t);
  -- kolom di luar allowlist (milik penerima / dipensiunkan) dibuang, sisanya tetap diterapkan
  bad := array(select k from jsonb_object_keys(case when jsonb_typeof(p -> 'row') = 'object' then p -> 'row' else '{}' end) k
                where not k = any (allowed || pk));
  if cardinality(bad) > 0 then
    perform bus.reject(jsonb_build_object('reason', 'columns', 'source', p_source, 'table', p ->> 'table', 'columns', to_jsonb(bad)));
    p := jsonb_set(p, '{row}', (p -> 'row') - bad);
  end if;
  -- delete hanya untuk tabel yang seluruh kolomnya milik pengirim: baris campuran (mis. profil dengan status/sanksi admin, org
  -- dengan fee admin) yang dihapus lalu dikirim ulang akan mengembalikan kolom milik penerima ke default. Dilewati + alert (tidak
  -- raise): delete baris campuran di pengirim (mis. hapus manual) tidak boleh menahan antrean selamanya.
  if p ->> 'op' = 'delete' and exists (select 1 from pg_attribute a where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                                                                    and not a.attname = any (allowed || pk)) then
    perform bus.reject(jsonb_build_object('reason', 'delete', 'source', p_source, 'table', p ->> 'table', 'key', p -> 'key'));
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
end $function$;

CREATE OR REPLACE FUNCTION bus.prune()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  delete from bus.outbox where sent_at < now() - interval '14 days';
  delete from bus.inbox where received_at < now() - interval '30 days';
$function$;

CREATE OR REPLACE FUNCTION bus.reject (
  p_detail jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if bus.me() = 'admin' then
    execute 'select ops.raise_alert($1, $2, $3)' using 'bus.rejected_payload', 'critical', p_detail;
  else
    perform bus.emit('admin', 'bus.rejected', p_detail || jsonb_build_object('at', bus.me()));
  end if;
end $function$;

REVOKE ALL ON FUNCTION "bus"."prune"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."prune"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."prune"() TO "postgres";

REVOKE ALL ON FUNCTION "bus"."reject"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."reject"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."reject"(jsonb) TO "postgres";

SELECT cron.schedule_in_database('bus-prune', '17 3 * * *', 'select bus.prune()', 'postgres', NULL, true);
