SET local check_function_bodies = off;

DROP FUNCTION "bus"."reconcile_apply"(integer);

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
  if p ->> 'op' = 'upsert' and exists (select 1 from bus.reconcile_runs x where x.source = p_source and x.tbl = t::text) then
    -- serial dengan job (kunci sama di bus.reconcile_apply): job tidak menghapus baris yang sedang dikirim ulang (O5-1)
    perform pg_advisory_xact_lock(hashtextextended('bus_reconcile:' || p_source || ':' || t::text, 0));
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
end $function$;

CREATE OR REPLACE FUNCTION bus.reconcile_apply (
  p_limit integer DEFAULT 2000
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
    -- kunci dipegang sampai job commit: upsert yang tiba bersamaan menunggu, lalu menulis ulang barisnya (O5-1)
    perform pg_advisory_xact_lock(hashtextextended('bus_reconcile:' || r.source || ':' || r.tbl, 0));
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
end $function$;

CREATE OR REPLACE FUNCTION bus.skip (
  p_target text,
  p_seq    bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  o bus.outbox;
begin
  select * into o from bus.outbox x where x.target = p_target and x.sent_at is null order by x.seq limit 1 for update;
  if not found or o.seq <> p_seq then
    raise exception 'bus_skip:bukan kepala antrean % (kepala: %)', p_target, o.seq using errcode = 'P0001';
  end if;
  -- ≥ 3 gagal per batch lalu ≥ 1 gagal dikirim SENDIRI (relay satu per satu sejak attempts ≥ 3): baru terbukti kepala = event
  -- yang gagal, bukan event sehat di depan event rusak dalam batch (O5-2)
  if o.attempts < 4 then
    raise exception 'bus_skip:kepala % belum terbukti gagal sendiri (attempts %, perlu >= 4)', o.seq, o.attempts using errcode = 'P0001';
  end if;
  update bus.outbox set sent_at = now(), request_id = null, last_error = 'dilewati operator ' || now() || ': ' || coalesce(last_error, '')
   where seq = o.seq;
  return jsonb_build_object('seq', o.seq, 'topic', o.topic, 'payload', o.payload, 'attempts', o.attempts, 'last_error', o.last_error);
end $function$;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."reconcile_apply"(integer) TO "postgres";
