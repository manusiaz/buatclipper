SET local check_function_bodies = off;

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
  perform set_config('bus.rejects', '', true);
  d := jsonb_build_object('source', p_source, 'count', jsonb_array_length(r),
                          'events', (select jsonb_agg(x) from (select x from jsonb_array_elements(r) x limit 10) f));
  if bus.me() = 'admin' then
    -- ops.raise_alert hanya ada di admin (fungsi ini dibagi ke creator/brand): dipanggil lewat regprocedure seperti handler bus_in
    execute format('select %s($1, $2, $3)', to_regprocedure('ops.raise_alert(text, text, jsonb, interval)')::regproc)
      using 'bus.rejected_payload', 'critical', d;
  else
    perform bus.emit('admin', 'bus.rejected', d);
  end if;
end $function$;
