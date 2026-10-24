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
    -- topik hanya dari pengirim yang memang memanggil bus.emit-nya (bus.accepts_topic); uji.ping = handler e2e/bus.sh yang
    -- hanya ada selama uji berjalan
    if not bus.accepts_topic(p_source, e ->> 'topic') and e ->> 'topic' <> 'uji.ping' then
      raise exception 'bus_not_allowed:% %', p_source, e ->> 'topic' using errcode = '42501';
    end if;
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc)  -- pengirim bus.ping = pengirim yang terautentikasi, bukan isi payload
      using case when e ->> 'topic' = 'bus.ping' then e -> 'payload' || jsonb_build_object('source', p_source) else e -> 'payload' end;
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION bus.accepts_topic (
  p_source text,
  p_topic  text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select false;
$function$;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."accepts_topic"(text, text) TO "postgres";
