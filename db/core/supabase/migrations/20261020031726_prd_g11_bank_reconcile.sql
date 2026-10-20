SET local check_function_bodies = off;

SELECT cron.unschedule('reconcile-daily');

CREATE TABLE "finance"."bank_lines" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "value_date"  date                     NOT NULL,
  "amount"      numeric(18,2)            NOT NULL,
  "reference"   text                     NOT NULL,
  "description" text                     NOT NULL DEFAULT ''::text,
  "line_hash"   text                     NOT NULL,
  "status"      text                     NOT NULL DEFAULT 'open'::text,
  "note"        text,
  "imported_by" uuid                     NOT NULL,
  "imported_at" timestamp with time zone NOT NULL DEFAULT now(),
  "resolved_by" uuid,
  "resolved_at" timestamp with time zone,
  CONSTRAINT "bank_lines_amount_check" CHECK ((amount <> (0)::numeric)),
  CONSTRAINT "bank_lines_description_check" CHECK ((length(description) <= 500)),
  CONSTRAINT "bank_lines_line_hash_key" UNIQUE (line_hash),
  CONSTRAINT "bank_lines_manual" CHECK (((status = 'manual'::text) = ((note IS NOT NULL) AND (resolved_by IS NOT NULL) AND (resolved_at IS NOT NULL)))),
  CONSTRAINT "bank_lines_note_check" CHECK (((length(note) >= 3) AND (length(note) <= 500))),
  CONSTRAINT "bank_lines_pkey" PRIMARY KEY (id),
  CONSTRAINT "bank_lines_reference_check" CHECK (((reference ~ '\S'::text) AND (length(reference) <= 120))),
  CONSTRAINT "bank_lines_status_check" CHECK ((status = ANY (ARRAY['open'::text, 'matched'::text, 'manual'::text])))
);

ALTER TABLE "finance"."bank_lines"
  ENABLE ROW LEVEL SECURITY;

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
      from x
  )
  insert into finance.bank_lines (value_date, amount, reference, description, line_hash, imported_by)
  select h.d, h.a, h.r, h.ds, h.hash, (select auth.uid()) from h where h.a <> 0
  on conflict (line_hash) do nothing;
  get diagnostics n = row_count;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_import', 'bank_lines', null,
          jsonb_build_object('lines', jsonb_array_length(p_lines), 'inserted', n));
  return jsonb_build_object('inserted', n, 'issues', finance.reconcile_bank());
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_bank_line (
  p_id   bigint,
  p_note text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) not between 3 and 500 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  update finance.bank_lines set status = 'manual', note = btrim(p_note), resolved_by = (select auth.uid()), resolved_at = now()
   where id = p_id and status = 'open';
  if not found then
    raise exception 'invalid_state:bank_line' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_resolve', 'bank_line:' || p_id, jsonb_build_object('status', 'open'),
          jsonb_build_object('status', 'manual', 'note', btrim(p_note)));
end $function$;

CREATE OR REPLACE FUNCTION finance.reconcile_bank()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  first_day date;
  last_day date;
  issues jsonb;
begin
  with sys as (
    select i.payment_ref ref, i.paid_amount amt from finance.invoices i where i.status = 'paid' and i.payment_channel in ('transfer', 'qris')
    union all
    select p.bank_ref, -(p.amount - p.fee) from finance.payouts p where p.status = 'paid' and p.channel = 'batch' and p.bank_ref is not null
    union all
    select r.bank_ref, -(r.amount - r.transfer_fee) from finance.org_refunds r where r.status = 'paid' and r.bank_ref is not null
  ), sys_t as (select s.ref, sum(s.amt) amt from sys s group by s.ref),
  bank_t as (select b.reference ref, sum(b.amount) amt from finance.bank_lines b where b.status <> 'manual' group by b.reference)
  update finance.bank_lines b
     set status = case when st.amt = bt.amt then 'matched' else 'open' end
    from bank_t bt left join sys_t st on st.ref = bt.ref
   where b.reference = bt.ref and b.status <> 'manual'
     and b.status <> case when st.amt = bt.amt then 'matched' else 'open' end;

  select min(b.value_date), max(b.value_date) into first_day, last_day from finance.bank_lines b;
  if first_day is null then
    return '{}';
  end if;
  select jsonb_strip_nulls(jsonb_build_object(
    'bank_unmatched', (select jsonb_agg(b.id order by b.id) from finance.bank_lines b where b.status = 'open'),
    'missing_in_bank', (select jsonb_agg(x.k order by x.k) from (
        select 'invoice:' || i.id k, i.payment_ref ref from finance.invoices i
         where i.status = 'paid' and i.payment_channel = 'transfer' and (i.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day
        union all
        select 'payout:' || p.id, p.bank_ref from finance.payouts p
         where p.status = 'paid' and p.channel = 'batch' and (p.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day
        union all
        select 'refund:' || r.id, r.bank_ref from finance.org_refunds r
         where r.status = 'paid' and (r.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day) x
      where x.ref is null or not exists (select 1 from finance.bank_lines b where b.reference = x.ref))))
    into issues;
  if issues <> '{}' then
    perform ops.raise_alert('reconcile.bank', 'critical', issues, interval '20 hours');
  end if;
  return issues;
end $function$;

CREATE OR REPLACE FUNCTION ops.notify_alerts (
  p_kind text DEFAULT NULL::text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
begin
  for r in select distinct on (a.kind) a.id, a.kind, a.severity from ops.alerts a
            where a.kind in ('tracking.lag', 'tracking.final_missing', 'fraud.flag_spike', 'payout.failed', 'payout.instant_stuck',
                             'reconcile.ledger', 'reconcile.orphans', 'reconcile.bank')
              and (p_kind is null or a.kind = p_kind)
              and a.notified_at is null and a.resolved_at is null and a.created_at > now() - interval '1 day'
              and not exists (select 1 from ops.alerts b where b.kind = a.kind and b.notified_at > now() - interval '1 hour')
            order by a.kind, a.id desc loop
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', r.kind, 'severity', r.severity,
                                                             'alert_id', r.id));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE VIEW "api"."bank_lines" WITH (security_invoker=true) AS  SELECT id,
    value_date,
    amount,
    reference,
    description,
    status,
    note,
    imported_at,
    resolved_at
   FROM finance.bank_lines;

CREATE INDEX bank_lines_open_idx ON finance.bank_lines USING btree (value_date)
  WHERE (status = 'open'::text);

CREATE INDEX bank_lines_reference_idx ON finance.bank_lines USING btree (reference);

CREATE POLICY "bank_lines_finance_read" ON "finance"."bank_lines"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "bank_lines_iss" ON "finance"."bank_lines"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

REVOKE ALL ON FUNCTION "api"."import_bank_lines"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."import_bank_lines"(jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."import_bank_lines"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."import_bank_lines"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."resolve_bank_line"(bigint, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."resolve_bank_line"(bigint, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."resolve_bank_line"(bigint, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."resolve_bank_line"(bigint, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."reconcile_bank"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."reconcile_bank"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."reconcile_bank"() TO "postgres";

GRANT SELECT ON TABLE "finance"."bank_lines" TO "authenticated";

GRANT SELECT ON TABLE "api"."bank_lines" TO "authenticated";

SELECT cron.schedule_in_database('reconcile-daily', '0 18 * * *', 'select finance.reconcile_ledger(); select finance.reconcile_bank();
                       select ops.invoke_function(''bridge'', ''{"action":"reconcile_ids"}'')', 'postgres', NULL, true);
