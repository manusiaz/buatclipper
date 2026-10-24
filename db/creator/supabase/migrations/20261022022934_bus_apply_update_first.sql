SET local check_function_bodies = off;

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
  n int := 0;
  h regprocedure;
begin
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
    -- yang belum/tidak ada di sini → dilewati.
    if upd is not null then
      execute format('update %1$s x set %2$s from jsonb_populate_record(null::%1$s, $1) r where %3$s', t, upd,
                     (select string_agg(format('x.%1$I = r.%1$I', c), ' and ') from unnest(pk) c))
        using p -> 'row';
      get diagnostics n = row_count;
    end if;
    if n = 0 then
      begin
        execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do nothing',
                       t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                       (select string_agg(format('%I', c), ', ') from unnest(pk) c))
          using p -> 'row';
      exception when not_null_violation then
        perform set_config('bus.applying', 'off', true);
        return;
      end;
    end if;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;
