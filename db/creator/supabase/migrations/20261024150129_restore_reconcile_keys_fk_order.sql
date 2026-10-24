SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus.replica_tables (
  p_target text
)
  RETURNS SETOF regclass
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  with recursive t as (
    select distinct tg.tgrelid as r from pg_trigger tg
     cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
     where tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target
  ), d (r, depth) as (
    select r, 0 from t
    union all
    select c.conrelid, d.depth + 1 from d
      join pg_constraint c on c.confrelid = d.r and c.contype = 'f' and c.conrelid <> c.confrelid and c.conrelid in (select r from t)
     where d.depth < 20
  )
  select r::regclass from d group by r order by max(depth), r::regclass::text;
$function$;
