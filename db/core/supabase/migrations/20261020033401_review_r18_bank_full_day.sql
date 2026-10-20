SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.import_bank_lines (
  p_lines jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
  partial date;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 5000
     or exists (select 1 from jsonb_array_elements(p_lines) e
                 where coalesce(e ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(e -> 'amount') is distinct from 'number'
                    or coalesce(btrim(e ->> 'reference'), '') = '' or length(e ->> 'reference') > 120) then
    raise exception 'invalid:bank_lines' using errcode = 'P0001';
  end if;
  with x as (
    select (e ->> 'date')::date d, round((e ->> 'amount')::numeric, 2) a, btrim(e ->> 'reference') r,
           left(coalesce(btrim(e ->> 'description'), ''), 500) ds
      from jsonb_array_elements(p_lines) e
  ), h as (
    select x.*, encode(sha256(convert_to(concat_ws('|', x.d, x.a, x.r, x.ds, row_number() over (partition by x.d, x.a, x.r, x.ds)),
                                         'UTF8')), 'hex') hash
      from x where x.a <> 0
  ), gap as (
    select min(b.value_date) d from finance.bank_lines b
     where b.value_date in (select h.d from h) and not exists (select 1 from h where h.hash = b.line_hash)
  ), ins as (
    insert into finance.bank_lines (value_date, amount, reference, description, line_hash, imported_by)
    select h.d, h.a, h.r, h.ds, h.hash, (select auth.uid()) from h where (select gap.d from gap) is null
    on conflict (line_hash) do nothing
    returning 1
  )
  select (select gap.d from gap), (select count(*) from ins) into partial, n;
  if partial is not null then
    raise exception 'bank_partial_day:%', partial using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_import', 'bank_lines', null,
          jsonb_build_object('lines', jsonb_array_length(p_lines), 'inserted', n));
  return jsonb_build_object('inserted', n, 'existing', jsonb_array_length(p_lines) - n, 'issues', finance.reconcile_bank());
end $function$;
