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
    h := case when e ->> 'topic' = 'rep.row' then 'bus.apply_row(jsonb)'::regprocedure  -- replikasi baris: handler bawaan
              else to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_'))) end;
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc) using e -> 'payload';
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;
