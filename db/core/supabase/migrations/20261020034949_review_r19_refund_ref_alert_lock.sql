SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.confirm_invoice_payment (
  p_invoice uuid,
  p_amount  numeric,
  p_paid_at timestamp with time zone,
  p_ref     text,
  p_channel text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  inv finance.invoices;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found then
    raise exception 'not_found:invoice' using errcode = 'P0002';
  end if;
  if inv.status = 'paid' and inv.payment_ref = p_ref then
    return;  -- replay konfirmasi yang sama
  end if;
  if inv.status <> 'issued' then
    raise exception 'invalid_state:%', inv.status using errcode = 'P0001';
  end if;
  if p_amount is distinct from inv.total - inv.credit_applied then  -- sisa tagihan setelah kredit org
    raise exception 'amount_mismatch' using errcode = 'P0001',
      detail = format('tagihan %s (total %s − kredit %s), dibayar %s', inv.total - inv.credit_applied, inv.total, inv.credit_applied, p_amount);
  end if;
  if p_ref is null or btrim(p_ref) = '' or p_channel is null or p_channel not in ('qris', 'transfer') then
    raise exception 'invalid:payment' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.invoices i where i.payment_ref = btrim(p_ref)) then
    raise exception 'duplicate_payment_ref' using errcode = '23505';
  end if;
  if inv.kind = 'campaign' and exists (select 1 from finance.invoices i where i.campaign_id = inv.campaign_id and i.kind = 'campaign'
                                                                        and i.status = 'paid') then
    raise exception 'campaign_already_funded' using errcode = 'P0001';
  end if;

  update finance.invoices set status = 'paid', payment_channel = p_channel, payment_ref = btrim(p_ref), paid_amount = p_amount,
         paid_at = coalesce(p_paid_at, now()), confirmed_by = (select auth.uid())
   where id = inv.id;
  perform finance.settle_invoice(inv);
  perform finance.reconcile_bank();
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'invoice.confirm_payment', 'invoice:' || inv.id, jsonb_build_object('status', inv.status),
          jsonb_build_object('status', 'paid', 'amount', p_amount, 'ref', btrim(p_ref), 'channel', p_channel, 'paid_at', p_paid_at));
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
  perform finance.reconcile_bank();  -- kas sistem berubah (paid / retur bank) → status baris mutasi ikut diperbarui
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
  settled boolean := true;  -- refund approved belum dibayar: referensi boleh diganti tanpa catatan (unggah bukti diulang)
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if ref = '' or length(ref) > 120 then
    raise exception 'invalid:bank_ref' using errcode = 'P0001';
  end if;
  if p_target = 'refund' then
    select r.bank_ref, r.status = 'paid' into old, settled from finance.org_refunds r
     where r.id = p_id and r.status in ('approved', 'paid') for update;
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
  if old is not null and settled and length(btrim(coalesce(p_note, ''))) < 3 then  -- koreksi transaksi yang sudah dibayar, wajib alasan
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
  perform finance.reconcile_bank();
  perform market.notify_org(r.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.paid',
                            market.campaign_ref(r.campaign_id) || finance.amount_ref(idr, r.amount - r.transfer_fee)
                            || jsonb_build_object('refund_id', r.id, 'transfer_fee', r.transfer_fee));
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
    continue when not pg_try_advisory_xact_lock(hashtext('ops.notify_alerts:' || r.kind));
    -- Setelah lock: transaksi lain yang baru commit mungkin sudah meminta kirim (snapshot statement baru).
    continue when exists (select 1 from ops.alerts b
                           where b.kind = r.kind and b.id <> r.id
                             and (b.notified_at > now() - interval '1 hour' or b.notify_requested_at > now() - interval '15 minutes'));
    update ops.alerts set notify_requested_at = now() where id = r.id;
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', r.kind, 'severity', r.severity,
                                                             'alert_id', r.id));
    n := n + 1;
  end loop;
  return n;
end $function$;
