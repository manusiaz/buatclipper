-- Konfirmasi pembayaran invoice brand (F-A08, J-A): admin_finance (aal2) mencatat nominal, waktu, referensi (unik).
-- Jurnal satu transaksi (ref_type invoice_payment, ref_id = invoice id):
--   bank_clearing(IDR)  −total                          kas masuk dari brand
--   campaign_pool(IDR)  +pool.total / +topup            pool Rupiah terisi (kind campaign / topup)
--   platform_revenue    +mgmt + admin + service fee     (+ subtotal untuk pinned/managed_service)
--   tax_payable         +tax
-- subtotal campaign/topup = tepat dana pool Rupiah (issue_invoice); beda → invoice_pool_mismatch (invoice basi, terbitkan ulang).
-- Pool non-tunai (Diamonds, voucher) = stok dari brand, bukan kas: bank_clearing(reward type itu) −total → campaign_pool +total.
-- Jurnal pelunasan bersama. Sumber dana: kas (bank_clearing, transfer/QRIS) sebesar total − credit_applied + org_credit sebesar
-- credit_applied (kredit org, D-09). Status invoice sudah paid.
create function finance.settle_invoice(inv finance.invoices) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

create function api.confirm_invoice_payment(p_invoice uuid, p_amount numeric, p_paid_at timestamptz, p_ref text, p_channel text)
returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Kredit org (rollover sisa budget, D-09): saldo akun org_credit Rupiah dikurangi refund yang masih berjalan (dananya sudah
-- di org_credit sejak diajukan, keluar saat dibayar). Sisa per campaign = saldo campaign_pool Rupiah (ledger, bukan cache).
create function finance.org_credit_available(p_org uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                     where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr()), 0)
         - coalesce((select sum(r.amount) from finance.org_refunds r where r.org_id = p_org and r.status in ('requested', 'approved')), 0)
         - coalesce((select sum(i.credit_applied) from finance.invoices i where i.org_id = p_org and i.status = 'issued'), 0);
$$;

create function api.org_credit(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
end $$;

-- Pakai kredit org untuk invoice (brand_owner/brand_finance aal2). p_amount = kredit yang dicadangkan (null = sebanyak mungkin,
-- 0 = lepas cadangan). Kredit menutup penuh → lunas (kanal credit, jurnal sama dengan transfer); sisanya dibayar transfer/QRIS
-- dan confirm_invoice_payment menagih total − credit_applied. Hasil: {credit_applied, due, paid}.
create function api.pay_invoice_with_credit(p_invoice uuid, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;


revoke execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text), finance.settle_invoice(finance.invoices),
  finance.org_credit_available(uuid), api.org_credit(uuid), api.pay_invoice_with_credit(uuid, numeric) from public;
grant execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text), api.org_credit(uuid),
  api.pay_invoice_with_credit(uuid, numeric) to authenticated;
