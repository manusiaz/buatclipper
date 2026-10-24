SET local check_function_bodies = off;

CREATE TABLE "bus"."replica_hooks" (
  "target_table" regclass     NOT NULL,
  "fn"           regprocedure NOT NULL,
  CONSTRAINT "replica_hooks_pkey" PRIMARY KEY (target_table)
);

ALTER TABLE "bus"."replica_hooks"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "bus"."replicas" (
  "source_table" regclass NOT NULL,
  "target"       text     NOT NULL,
  "columns"      text[]   NOT NULL,
  CONSTRAINT "replicas_pkey" PRIMARY KEY (source_table, target),
  CONSTRAINT "replicas_target_check" CHECK ((target = ANY (ARRAY['identity'::text, 'creator'::text, 'brand'::text, 'admin'::text])))
);

ALTER TABLE "bus"."replicas"
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
    if exists (select 1 from bus.inbox i where i.id = (e ->> 'id')::uuid) then
      skipped := skipped + 1;
      continue;
    end if;
    select bh.fn into h from bus.handlers bh where bh.topic = e ->> 'topic';
    if h is null and e ->> 'topic' = 'rep.row' then
      h := 'bus.apply_row(jsonb)'::regprocedure;  -- replikasi baris: handler bawaan
    end if;
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
  select rh.fn into h from bus.replica_hooks rh where rh.target_table = t;
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus.pk_columns (
  p_table regclass
)
  RETURNS text[]
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select array_agg(a.attname::text order by k.ord)
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indrelid = p_table and i.indisprimary;
$function$;

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
  for r in select b.target, b.columns from bus.replicas b where b.source_table = tg_relid order by b.target loop
    continue when tg_op = 'UPDATE' and not exists (select 1 from unnest(r.columns) c where newj -> c is distinct from oldj -> c);
    perform bus.emit(r.target, 'rep.row', jsonb_build_object(
      'table', tg_relid::regclass::text,
      'op', case when tg_op = 'DELETE' then 'delete' else 'upsert' end,
      'key', (select jsonb_object_agg(k, coalesce(newj, oldj) -> k) from unnest(pk) k),
      'row', case when tg_op <> 'DELETE' then (select jsonb_object_agg(c, newj -> c) from unnest(r.columns || pk) c) end));
  end loop;
  return null;
end $function$;

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."apply_row"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."pk_columns"(regclass) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."pk_columns"(regclass) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."pk_columns"(regclass) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."replicate"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."replicate"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."replicate"() TO "postgres";
