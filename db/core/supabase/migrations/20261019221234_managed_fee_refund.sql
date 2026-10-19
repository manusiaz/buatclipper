SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION finance.refund_cancelled_campaign (
  p_campaign uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
  idr uuid := finance.idr();
  key text := 'cancel:' || p_campaign;
  rid uuid;
  fees numeric;
  tx numeric;
  pool_idr numeric := 0;
  refund_amount numeric;
  x record;
  pools jsonb := '[]';
  entries jsonb := '[]';
begin
  select * into c from market.campaigns k where k.id = p_campaign;
  if not found or c.status <> 'cancelled' then
    raise exception 'invalid_state:%', coalesce(c.status::text, 'missing') using errcode = 'P0001';
  end if;
  update finance.invoices set status = 'void' where campaign_id = c.id and status = 'issued';
  select r.id into rid from finance.org_refunds r where r.idempotency_key = key;
  if rid is not null then
    return rid;
  end if;
  select coalesce(sum(i.mgmt_fee + i.admin_fee + i.service_fee + case when i.kind = 'pinned' then i.subtotal else 0 end), 0),
         coalesce(sum(i.tax), 0)
    into fees, tx
    from finance.invoices i where i.campaign_id = c.id and i.status = 'paid' and i.kind in ('campaign', 'topup', 'pinned', 'managed_service');
  perform 1 from finance.reward_pools rp where rp.campaign_id = c.id order by rp.id for update;
  for x in select rp.reward_type_id as rt, a.id as account, finance.balance(a.id) as bal
             from finance.reward_pools rp
             join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
            where rp.campaign_id = c.id and finance.balance(a.id) > 0 order by rp.id loop
    pools := pools || jsonb_build_array(jsonb_build_object('rt', x.rt, 'account', x.account, 'bal', x.bal));
    if x.rt = idr then
      pool_idr := pool_idr + x.bal;
    end if;
  end loop;
  refund_amount := pool_idr + fees + tx;
  if refund_amount <= 0 and pools = '[]' then
    return null;  -- belum ada yang dibayar
  end if;
  if refund_amount > 0 then
    insert into finance.org_refunds (org_id, campaign_id, amount, transfer_fee, requested_by, idempotency_key)
    values (c.org_id, c.id, refund_amount, 0, coalesce((select auth.uid()), c.created_by), key) returning id into rid;
  else
    rid := gen_random_uuid();  -- hanya stok non-tunai yang dikembalikan
  end if;
  for x in select (p ->> 'rt')::uuid as rt, (p ->> 'account')::uuid as account, (p ->> 'bal')::numeric as bal
             from jsonb_array_elements(pools) p loop
    entries := entries || jsonb_build_array(finance.e(x.account, -x.bal, 'refund', rid::text));
    if x.rt <> idr then
      entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, x.rt), x.bal, 'refund', rid::text));
    end if;
  end loop;
  entries := entries || jsonb_build_array(
    finance.e(finance.account('platform_revenue', null, idr), -fees, 'refund', rid::text),
    finance.e(finance.account('tax_payable', null, idr), -tx, 'refund', rid::text),
    finance.e(finance.account('org_credit', c.org_id, idr), refund_amount, 'refund', rid::text));
  perform finance.post(gen_random_uuid(), entries);
  if refund_amount > 0 then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.requested',
                              market.campaign_ref(c.id) || finance.amount_ref(idr, refund_amount) || jsonb_build_object('refund_id', rid));
    return rid;
  end if;
  return null;
end $function$;
