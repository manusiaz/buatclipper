-- Konfirmasi pembayaran invoice brand (F-A08, J-A): admin_finance (aal2) mencatat nominal, waktu, referensi (unik).
-- Jurnal satu transaksi (ref_type invoice_payment, ref_id = invoice id):
--   bank_clearing(IDR)  −total                          kas masuk dari brand
--   campaign_pool(IDR)  +pool.total / +topup            pool Rupiah terisi (kind campaign / topup)
--   platform_revenue    +mgmt + admin + service fee     (+ subtotal untuk pinned/managed_service)
--   tax_payable         +tax
-- subtotal campaign/topup = tepat dana pool Rupiah (issue_invoice); beda → invoice_pool_mismatch (invoice basi, terbitkan ulang).
-- Pool non-tunai (Diamonds, voucher) = stok dari brand, bukan kas: bank_clearing(reward type itu) −total → campaign_pool +total.
create function api.confirm_invoice_payment(p_invoice uuid, p_amount numeric, p_paid_at timestamptz, p_ref text, p_channel text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  inv finance.invoices;
  idr uuid := finance.idr();
  bank uuid;
  entries jsonb := '[]';
  pool_idr numeric := 0;
  revenue numeric;
  x record;
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
  if p_amount is distinct from inv.total then
    raise exception 'amount_mismatch' using errcode = 'P0001', detail = format('invoice %s, dibayar %s', inv.total, p_amount);
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

  bank := finance.account('bank_clearing', null, idr);
  entries := jsonb_build_array(finance.e(bank, -inv.total, 'invoice_payment', inv.id::text),
                               finance.e(finance.account('tax_payable', null, idr), inv.tax, 'invoice_payment', inv.id::text));
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
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, p_amount)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $$;

revoke execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text) from public;
grant execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text) to authenticated;
