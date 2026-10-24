SET local check_function_bodies = off;

ALTER TABLE "ops"."alerts"
  ADD COLUMN "notify_requested_at" timestamp WITH time zone;

CREATE OR REPLACE FUNCTION api.bank_issues()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  return finance.bank_issues();
end $function$;

CREATE OR REPLACE FUNCTION api.mark_batch_paid (
  p_batch   uuid,
  p_results jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found or b.status not in ('exported', 'paid', 'closed') then
    raise exception 'batch_not_exported' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception 'invalid:results' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text, reason text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' and not (po.status = 'paid' and x.status = 'failed') then  -- paid → failed = retur bank
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      if coalesce(btrim(x.bank_ref), '') = '' then  -- referensi mutasi wajib: rekonsiliasi bank (A3.5) mencocokkan per referensi
        raise exception 'invalid:bank_ref' using errcode = 'P0001';
      end if;
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = btrim(x.bank_ref) where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', finance.amount_ref(finance.idr(), po.amount - po.fee)
                                       || jsonb_build_object('payout_id', po.id, 'channel', po.channel));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id, coalesce(nullif(btrim(x.reason), ''), 'transfer gagal (batch)'));
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.mark_paid', 'payout_batch:' || p_batch, jsonb_build_object('status', b.status),
          jsonb_build_object('results', p_results));
end $function$;

CREATE OR REPLACE FUNCTION api.set_bank_ref (
  p_target text,
  p_id     uuid,
  p_ref    text,
  p_note   text DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  ref text := btrim(coalesce(p_ref, ''));
  old text;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if ref = '' or length(ref) > 120 then
    raise exception 'invalid:bank_ref' using errcode = 'P0001';
  end if;
  if p_target = 'refund' then
    select r.bank_ref into old from finance.org_refunds r where r.id = p_id and r.status in ('approved', 'paid') for update;
  elsif p_target = 'payout' then
    select p.bank_ref into old from finance.payouts p where p.id = p_id and p.status = 'paid' and p.channel = 'batch' for update;
  elsif p_target = 'invoice' then
    select i.payment_ref into old from finance.invoices i where i.id = p_id and i.status = 'paid' and i.payment_channel in ('transfer', 'qris')
       for update;
  else
    raise exception 'invalid:target' using errcode = 'P0001';
  end if;
  if not found then
    raise exception 'not_found:%', p_target using errcode = 'P0002';
  end if;
  if old is not distinct from ref then
    return finance.reconcile_bank();
  end if;
  if old is not null and length(btrim(coalesce(p_note, ''))) < 3 then  -- mengganti referensi yang sudah ada = koreksi, wajib alasan
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  if p_target = 'refund' then
    update finance.org_refunds set bank_ref = ref where id = p_id;
  elsif p_target = 'payout' then
    update finance.payouts set bank_ref = ref where id = p_id;
  else
    if exists (select 1 from finance.invoices i where i.payment_ref = ref) then
      raise exception 'duplicate_payment_ref' using errcode = '23505';
    end if;
    update finance.invoices set payment_ref = ref where id = p_id;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_ref', p_target || ':' || p_id, jsonb_build_object('ref', old),
          jsonb_build_object('ref', ref, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  return finance.reconcile_bank();
end $function$;

CREATE OR REPLACE FUNCTION finance.bank_issues()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  first_day date;
  last_day date;
begin
  select min(b.value_date), max(b.value_date) into first_day, last_day from finance.bank_lines b;
  if first_day is null then
    return '{}';
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
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
      where x.ref is null or not exists (select 1 from finance.bank_lines b where b.reference = x.ref))));
end $function$;

CREATE OR REPLACE FUNCTION finance.pay_refund (
  p_refund    uuid,
  p_proof_ref text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r finance.org_refunds;
  idr uuid := finance.idr();
begin
  select * into r from finance.org_refunds o where o.id = p_refund for update;
  if not found then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  if r.status = 'paid' then
    return;
  end if;
  if r.status <> 'approved' then
    raise exception 'invalid_state:%', r.status using errcode = 'P0001';
  end if;
  if r.bank_ref is null then  -- diisi api.set_bank_ref sebelum bukti diunggah (rekonsiliasi bank per referensi)
    raise exception 'invalid:bank_ref' using errcode = 'P0001';
  end if;
  update finance.org_refunds set status = 'paid', paid_at = now(), proof_ref = p_proof_ref where id = r.id;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(finance.account('org_credit', r.org_id, idr), -r.amount, 'refund', r.id || ':paid'),
    finance.e(finance.account('bank_clearing', null, idr), r.amount - r.transfer_fee, 'refund', r.id || ':paid'),
    finance.e(finance.account('platform_revenue', null, idr), r.transfer_fee, 'refund', r.id || ':paid')));
  perform market.notify_org(r.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.paid',
                            market.campaign_ref(r.campaign_id) || finance.amount_ref(idr, r.amount - r.transfer_fee)
                            || jsonb_build_object('refund_id', r.id, 'transfer_fee', r.transfer_fee));
end $function$;

CREATE OR REPLACE FUNCTION finance.reconcile_bank()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
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

  issues := finance.bank_issues();
  if issues <> '{}' and not coalesce((select a.payload from ops.alerts a where a.kind = 'reconcile.bank' and a.resolved_at is null
                                       order by a.id desc limit 1) @> issues, false) then
    perform ops.raise_alert('reconcile.bank', 'critical', issues);
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
              and not exists (select 1 from ops.alerts b
                               where b.kind = a.kind and (b.notified_at > now() - interval '1 hour'
                                                          or b.notify_requested_at > now() - interval '15 minutes'))
            order by a.kind, a.id desc loop
    update ops.alerts set notify_requested_at = now() where id = r.id;
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', r.kind, 'severity', r.severity,
                                                             'alert_id', r.id));
    n := n + 1;
  end loop;
  return n;
end $function$;

REVOKE ALL ON FUNCTION "api"."bank_issues"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."bank_issues"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."bank_issues"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bank_issues"() TO "postgres";

REVOKE ALL ON FUNCTION "api"."set_bank_ref"(text, uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."set_bank_ref"(text, uuid, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."set_bank_ref"(text, uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."set_bank_ref"(text, uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."bank_issues"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."bank_issues"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."bank_issues"() TO "postgres";
