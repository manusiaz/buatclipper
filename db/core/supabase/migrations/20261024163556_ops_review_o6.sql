SET local check_function_bodies = off;

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
    perform pg_advisory_xact_lock(hashtextextended('bus_reconcile:' || r.source, 0));
    -- dibaca ulang sesudah kunci: pemanggil lain (cron + manual) bisa sudah menyelesaikan run ini dan menghapus daftarnya —
    -- run basi + daftar kosong = hapus massal (O6-1)
    continue when not exists (select 1 from bus.reconcile_runs x where x.source = r.source and x.tbl = r.tbl and x.epoch = r.epoch);
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
