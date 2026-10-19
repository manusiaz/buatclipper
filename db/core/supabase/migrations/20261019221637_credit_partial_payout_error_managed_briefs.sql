SET local check_function_bodies = off;

DROP VIEW "api"."payouts";

DROP FUNCTION "api"."pay_invoice_with_credit"(uuid);

DROP FUNCTION "finance"."settle_invoice"(finance.invoices, uuid);

ALTER TABLE "finance"."invoices"
  ADD COLUMN "credit_applied" numeric(18,2) NOT NULL DEFAULT 0;

ALTER TABLE "finance"."payouts"
  ADD COLUMN "last_error" text;

CREATE OR REPLACE FUNCTION api.bridge_get_batch (
  p_batch uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
begin
  select * into b from finance.payout_batches x where x.id = p_batch;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status not in ('approved', 'exported') then  -- exported: identity menandatangani ulang link berkas yang sama
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'batch', jsonb_build_object('id', b.id, 'status', b.status, 'created_by', b.created_by, 'approved_by', b.approved_by),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id,
                                                             'amount', p.amount, 'fee', p.fee) order by p.id)
                         from finance.payouts p where p.batch_id = b.id and p.status = 'requested'), '[]'));
end $function$;

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
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = x.bank_ref where id = po.id;
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

CREATE OR REPLACE FUNCTION api.org_credit (
  p_org uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  acc uuid;
begin
  perform market.session_uid();
  if not (ops.is_org_member(p_org, 'brand_owner', 'brand_finance') or ops.has_admin('admin_finance')) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_finance', '42501');
  end if;
  select a.id into acc from finance.ledger_accounts a
   where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr();
  return jsonb_build_object(
    'balance', trim_scale(coalesce(finance.balance(acc), 0)),
    'available', trim_scale(finance.org_credit_available(p_org)),
    'reserved', trim_scale(coalesce((select sum(i.credit_applied) from finance.invoices i where i.org_id = p_org and i.status = 'issued'), 0)),
    'history', coalesce((select jsonb_agg(jsonb_build_object('amount', trim_scale(e.amount), 'ref_type', e.ref_type, 'ref_id', e.ref_id,
                                                             'created_at', e.created_at) order by e.created_at desc)
                           from (select * from finance.ledger_entries x where x.account_id = acc
                                  order by x.created_at desc limit 50) e), '[]'::jsonb),
    'leftovers', coalesce((select jsonb_agg(jsonb_build_object('campaign_id', c.id, 'title', c.title, 'amount', trim_scale(l.amount)))
                             from market.campaigns c
                             cross join lateral (select sum(finance.balance(a.id)) as amount
                                                   from finance.reward_pools rp
                                                   join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                                  where rp.campaign_id = c.id and rp.reward_type_id = finance.idr()) l
                            where c.org_id = p_org and c.status in ('settled', 'cancelled') and l.amount > 0), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION api.pay_invoice_with_credit (
  p_invoice uuid,
  p_amount  numeric DEFAULT NULL::numeric
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  inv finance.invoices;
  want numeric;
begin
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found or not ops.is_org_member(inv.org_id, 'brand_owner', 'brand_finance') then
    perform market.fail('not_found:invoice', null, 'P0002');
  end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    perform market.fail('auth:mfa_required', 'aksi uang brand butuh aal2', '42501');
  end if;
  if inv.status = 'paid' and inv.payment_ref = 'credit:' || inv.id then
    return jsonb_build_object('credit_applied', trim_scale(inv.credit_applied), 'due', 0, 'paid', true);
  end if;
  if inv.status <> 'issued' then
    perform market.fail('invalid_state:' || inv.status);
  end if;
  if p_amount is not null and (p_amount < 0 or p_amount <> round(p_amount, 2)) then
    perform market.fail('invalid:amount', 'kredit ≥ 0, maksimal 2 desimal');
  end if;
  if inv.kind = 'campaign' and exists (select 1 from finance.invoices i where i.campaign_id = inv.campaign_id and i.kind = 'campaign'
                                                                        and i.status = 'paid') then
    perform market.fail('campaign_already_funded');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('org_credit:' || inv.org_id, 0));
  -- tersedia + cadangan invoice ini sendiri = yang boleh dipakai untuk invoice ini
  want := least(inv.total, finance.org_credit_available(inv.org_id) + inv.credit_applied);
  if p_amount is not null then
    if p_amount > want then
      perform market.fail('insufficient_credit', format('kredit bisa dipakai %s, diminta %s', want, p_amount));
    end if;
    want := p_amount;
  elsif want <= inv.credit_applied then
    perform market.fail('insufficient_credit', 'tidak ada kredit tersedia');
  end if;
  update finance.invoices set credit_applied = want where id = inv.id returning * into inv;
  if inv.credit_applied = inv.total then
    update finance.invoices set status = 'paid', payment_channel = 'credit', payment_ref = 'credit:' || inv.id, paid_amount = inv.total,
           paid_at = now(), confirmed_by = uid
     where id = inv.id returning * into inv;
    perform finance.settle_invoice(inv);
  end if;
  return jsonb_build_object('credit_applied', trim_scale(inv.credit_applied), 'due', trim_scale(inv.total - inv.credit_applied),
                            'paid', inv.status = 'paid');
end $function$;

CREATE OR REPLACE FUNCTION finance.org_credit_available (
  p_org uuid
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                     where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr()), 0)
         - coalesce((select sum(r.amount) from finance.org_refunds r where r.org_id = p_org and r.status in ('requested', 'approved')), 0)
         - coalesce((select sum(i.credit_applied) from finance.invoices i where i.org_id = p_org and i.status = 'issued'), 0);
$function$;

CREATE OR REPLACE FUNCTION finance.reconcile_ledger()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  idr uuid := finance.idr();
  issues jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'pool_cache', (select jsonb_agg(rp.id) from finance.reward_pools rp
                    where rp.allocated <> coalesce((select -sum(e.amount) from finance.ledger_entries e
                                                      join finance.ledger_accounts a on a.id = e.account_id
                                                     where a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                                       and e.ref_type in ('accrual', 'reversal', 'release')), 0)),
    'negative_wallet', (select jsonb_agg(a.id) from finance.ledger_accounts a
                         where a.owner_type = 'user_wallet'
                           and (select coalesce(sum(e.amount), 0) from finance.ledger_entries e
                                 where e.account_id = a.id and e.state in ('pending', 'available')) < 0),
    'invoice_unposted', (select jsonb_agg(i.id) from finance.invoices i
                          where i.status = 'paid'
                            and (select coalesce(sum(e.amount), 0) from finance.ledger_entries e
                                   join finance.ledger_accounts a on a.id = e.account_id
                                  where e.ref_type = 'invoice_payment' and e.ref_id = i.id::text
                                    and a.owner_type in ('bank_clearing', 'org_credit') and a.reward_type_id = idr) <> -i.total),
    'journal_without_invoice', (select jsonb_agg(distinct e.ref_id) from finance.ledger_entries e
                                 where e.ref_type = 'invoice_payment'
                                   and not exists (select 1 from finance.invoices i where i.id::text = e.ref_id and i.status = 'paid'))))
    into issues;
  if issues <> '{}' then
    perform ops.raise_alert('reconcile.ledger', 'critical', issues);
  end if;
  return issues;
end $function$;

CREATE OR REPLACE FUNCTION finance.return_payout (
  p_payout uuid,
  p_error  text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
  idr uuid := finance.idr();
begin
  select * into po from finance.payouts p where p.id = p_payout for update;
  if po.status = 'returned' then
    return;
  end if;
  if po.status in ('processing', 'paid') then
    update finance.payouts set status = 'failed', last_error = left(p_error, 500) where id = po.id;
  end if;
  update finance.payouts set status = 'returned' where id = po.id;  -- trigger S-05 menolak kalau bukan dari failed
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.failed', finance.amount_ref(idr, po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', left(p_error, 200)));
  perform ops.raise_alert('payout.failed', 'warning', jsonb_build_object('payout_id', po.id, 'channel', po.channel,
                                                                           'amount', po.amount, 'error', left(p_error, 500)));
end $function$;

CREATE OR REPLACE FUNCTION finance.settle_invoice (
  inv finance.invoices
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  idr uuid := finance.idr();
  entries jsonb := '[]';
  pool_idr numeric := 0;
  revenue numeric;
  x record;
begin
  entries := jsonb_build_array(finance.e(finance.account('tax_payable', null, idr), inv.tax, 'invoice_payment', inv.id::text));
  if inv.total > inv.credit_applied then
    entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, idr), -(inv.total - inv.credit_applied),
                                                      'invoice_payment', inv.id::text));
  end if;
  if inv.credit_applied > 0 then
    entries := entries || jsonb_build_array(finance.e(finance.account('org_credit', inv.org_id, idr), -inv.credit_applied,
                                                      'invoice_payment', inv.id::text));
  end if;
  revenue := inv.mgmt_fee + inv.admin_fee + inv.service_fee;

  if inv.kind in ('campaign', 'topup') then
    for x in
      select rp.id, rp.reward_type_id, rp.campaign_id, coalesce(t.amount, rp.total) as amount
        from finance.reward_pools rp
        left join (select (e ->> 'pool_id')::uuid as pool_id, sum((e ->> 'amount')::numeric) as amount
                     from jsonb_array_elements(coalesce(inv.pool_topups, '[]')) e group by 1) t on t.pool_id = rp.id
       where rp.campaign_id = inv.campaign_id and (inv.kind = 'campaign' or t.pool_id is not null)
       order by rp.id
      for update of rp
    loop
      if x.amount is null or x.amount <= 0 then
        raise exception 'invalid:pool_topups' using errcode = 'P0001';
      end if;
      if inv.kind = 'topup' then
        update finance.reward_pools set total = total + x.amount where id = x.id;
      end if;
      entries := entries || jsonb_build_array(finance.e(finance.account('campaign_pool', x.id, x.reward_type_id), x.amount,
                                                        'invoice_payment', inv.id::text));
      if x.reward_type_id = idr then
        pool_idr := pool_idr + x.amount;
      else
        entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, x.reward_type_id), -x.amount,
                                                          'invoice_payment', inv.id::text));
      end if;
    end loop;
    if inv.kind = 'topup' and (select count(distinct e ->> 'pool_id') from jsonb_array_elements(inv.pool_topups) e)
         <> (select count(*) from finance.reward_pools rp join jsonb_array_elements(inv.pool_topups) e on (e ->> 'pool_id')::uuid = rp.id
             where rp.campaign_id = inv.campaign_id) then
      raise exception 'invalid:pool_topups' using errcode = 'P0001';  -- pool milik campaign lain / tidak ada
    end if;
    if pool_idr <> inv.subtotal then
      raise exception 'invoice_pool_mismatch' using errcode = 'P0001',
        detail = format('pool Rupiah %s ≠ subtotal %s', pool_idr, inv.subtotal);
    end if;
  else
    revenue := revenue + inv.subtotal;
  end if;
  entries := entries || jsonb_build_array(finance.e(finance.account('platform_revenue', null, idr), revenue,
                                                    'invoice_payment', inv.id::text));
  perform finance.post(gen_random_uuid(), entries);

  if inv.kind = 'pinned' then
    update market.campaigns set pinned_until = greatest(coalesce(pinned_until, inv.pin_until), inv.pin_until)
     where id = inv.campaign_id;
  end if;
  perform market.notify_org(inv.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.paid',
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, inv.total)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $function$;

ALTER TABLE "finance"."invoices"
  ADD CONSTRAINT "invoices_credit_applied_check" CHECK ((credit_applied >= (0)::numeric));

ALTER TABLE "finance"."invoices"
  ADD CONSTRAINT "invoices_credit_within_total" CHECK ((credit_applied <= total));

ALTER TABLE "finance"."payouts"
  ADD CONSTRAINT "payouts_last_error_check" CHECK ((char_length(last_error) <= 500));

CREATE VIEW "api"."managed_briefs" WITH (security_invoker=true) AS  SELECT id AS campaign_id,
    managed_brief
   FROM market.campaigns c
  WHERE ((service_mode = 'managed'::text) AND (( SELECT ops.is_org_member(c.org_id) AS is_org_member) OR ( SELECT ops.has_admin() AS has_admin)));

CREATE VIEW "api"."payouts" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    method_id,
    batch_id,
    channel,
    amount,
    fee,
    status,
    hold_reason,
    bank_ref,
    provider_ref,
    last_error,
    created_at,
    paid_at
   FROM finance.payouts;

REVOKE ALL ON FUNCTION "api"."pay_invoice_with_credit"(uuid, numeric) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."pay_invoice_with_credit"(uuid, numeric) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."pay_invoice_with_credit"(uuid, numeric) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."pay_invoice_with_credit"(uuid, numeric) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."settle_invoice"(finance.invoices) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."settle_invoice"(finance.invoices) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."settle_invoice"(finance.invoices) TO "postgres";

GRANT SELECT ON TABLE "api"."managed_briefs" TO "authenticated";

GRANT SELECT ON TABLE "api"."payouts" TO "authenticated";
