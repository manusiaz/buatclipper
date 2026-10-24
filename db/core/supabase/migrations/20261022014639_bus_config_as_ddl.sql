SET local check_function_bodies = off;

DROP TABLE "bus"."handlers";

DROP TABLE "bus"."replica_hooks";

DROP TABLE "bus"."replicas";

CREATE SCHEMA "bus_in";

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
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION bus.replicate()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;
