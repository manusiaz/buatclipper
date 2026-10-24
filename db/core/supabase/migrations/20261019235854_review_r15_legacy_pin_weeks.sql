SET local check_function_bodies = off;

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
  days int;
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

  -- Pin berlaku sejak lunas (atau sejak pin yang sedang berjalan habis), selama hari yang dibeli; campaign dikunci supaya
  -- dua invoice pin yang lunas bersamaan saling menyambung, tidak tumpang tindih.
  -- Invoice terbit sebelum pin_days ada: durasi = periode perkiraannya (pin_until − issued_at), dibatasi minggu yang dibayar
  -- (service_fee ÷ harga per minggu) karena periode itu ikut memuat sisa pin yang sedang berjalan saat terbit; maks 90 hari.
  if inv.kind = 'pinned' then
    days := coalesce(inv.pin_days, least(90, greatest(1,
      least(ceil(extract(epoch from inv.pin_until - inv.issued_at) / 86400),
            7 * round(inv.service_fee / nullif((select (s.value #>> '{}')::numeric from ops.settings s
                                                where s.key = 'public.billing.pin_price_per_week_idr'), 0))))));
    update market.campaigns set pinned_until = greatest(now(), coalesce(pinned_until, now())) + make_interval(days => days)
     where id = inv.campaign_id
    returning pinned_until into inv.pin_until;
    update finance.invoices set pin_until = inv.pin_until where id = inv.id;
  end if;
  perform market.notify_org(inv.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.paid',
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, inv.total)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $function$;
