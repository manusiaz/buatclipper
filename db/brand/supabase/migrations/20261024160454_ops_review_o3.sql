SET local check_function_bodies = off;

CREATE TABLE "bus"."reconcile_runs" (
  "source"     text                     NOT NULL,
  "tbl"        text                     NOT NULL,
  "epoch"      uuid                     NOT NULL,
  "total"      bigint                   NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "reconcile_runs_pkey" PRIMARY KEY (source, tbl, epoch)
);

ALTER TABLE "bus"."reconcile_runs"
  ENABLE ROW LEVEL SECURITY;

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
end $function$;

CREATE OR REPLACE FUNCTION bus.prune()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  delete from bus.outbox where sent_at < now() - interval '14 days';
  -- rekonsiliasi yang terputus (potongan terakhir tak tiba); daftar lengkap yang masih diproses bus.reconcile_apply tidak disentuh
  delete from bus.reconcile_keys k where k.created_at < now() - interval '7 days'
     and not exists (select 1 from bus.reconcile_runs r where r.source = k.source and r.tbl = k.tbl and r.epoch = k.epoch);
$function$;

CREATE OR REPLACE FUNCTION bus.reconcile_apply (
  p_limit integer DEFAULT 5000
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

CREATE OR REPLACE FUNCTION bus.reject (
  p_detail jsonb
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select set_config('bus.rejects', case when jsonb_array_length(r) < 10 then r || jsonb_build_array(p_detail) else r end::text, true),
         set_config('bus.rejects_n', (coalesce(nullif(current_setting('bus.rejects_n', true), ''), '0')::int + 1)::text, true)
    from (select coalesce(nullif(current_setting('bus.rejects', true), ''), '[]')::jsonb r) x;
$function$;

CREATE OR REPLACE FUNCTION bus.report_rejects (
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."reconcile_apply"(integer) TO "postgres";

SELECT cron.schedule_in_database('bus-reconcile', '30 seconds', 'select bus.reconcile_apply()', 'postgres', NULL, true);
