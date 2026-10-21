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
  days int;
begin
  -- Top-up / pin tak bermakna lagi bila campaign tidak bisa berjalan lagi (deadline lewat, habis, selesai, batal, ditolak) →
  -- tolak; invoice basi di-void lifecycle (finance.void_stale_addons).
  if inv.kind in ('topup', 'pinned') then
    perform 1 from market.campaigns c where c.id = inv.campaign_id
       and c.status in ('tracking', 'exhausted', 'settling', 'settled', 'cancelled', 'rejected') for share;
    if found then
      raise exception 'invoice_campaign_closed' using errcode = 'P0001';
    end if;
  end if;
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
  perform finance.reconcile_bank();
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
-- D-09 rollover "tanpa fee baru": kredit rollover (jurnal ref_type rollover ke org_credit) yang belum dipakai membebaskan fee
-- invoice campaign/top-up berikutnya; dikurangi fee_exempt invoice yang tidak void (void = kembali tersedia).
create function finance.rollover_available(p_org uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select greatest(
    coalesce((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
               where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr()
                 and e.ref_type = 'rollover' and e.amount > 0), 0)
    - coalesce((select sum(i.fee_exempt) from finance.invoices i where i.org_id = p_org and i.status <> 'void'), 0), 0);
$$;

create function api.pay_invoice_with_credit(p_invoice uuid, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  inv finance.invoices;
  want numeric;
  ex numeric;
  base numeric;
  new_mgmt numeric;
  new_adm numeric;
  new_tax numeric;
  g jsonb;
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
  -- Porsi budget yang didanai rollover (≤ kredit yang dipakai) tidak dikenai fee lagi: fee mgmt/admin dihitung ulang dari fee
  -- awal (fee_gross) atas dasar dikurangi porsi itu, pajak ikut, total turun sebelum kredit diterapkan. Dihitung ulang tiap
  -- cadangan berubah; dilepas (0) → fee awal kembali. Rollover yang sudah dipakai invoice ini tetap tersedia untuknya.
  if inv.kind in ('campaign', 'topup') then
    g := coalesce(inv.fee_gross, jsonb_build_object('mgmt_fee', inv.mgmt_fee, 'admin_fee', inv.admin_fee, 'tax', inv.tax));
    ex := least(finance.rollover_available(inv.org_id) + inv.fee_exempt, finance.org_credit_available(inv.org_id) + inv.credit_applied,
                inv.subtotal, coalesce(p_amount, inv.subtotal));
    base := inv.subtotal + finance.noncash_value_idr(inv.campaign_id, case when inv.kind = 'topup' then inv.pool_topups end);
    if ex > 0 and base > 0 then
      new_mgmt := round((base - ex) * (g ->> 'mgmt_fee')::numeric / base, 2);
      new_adm := round((base - ex) * (g ->> 'admin_fee')::numeric / base, 2);
      new_tax := round((new_mgmt + new_adm + inv.service_fee)
                       * coalesce((select (st.value #>> '{}')::numeric from ops.settings st where st.key = 'public.billing.tax_pct'), 11) / 100, 2);
    else
      ex := 0;
      new_mgmt := (g ->> 'mgmt_fee')::numeric;
      new_adm := (g ->> 'admin_fee')::numeric;
      new_tax := (g ->> 'tax')::numeric;
    end if;
    update finance.invoices set fee_exempt = ex, fee_gross = case when ex > 0 then g end, mgmt_fee = new_mgmt, admin_fee = new_adm,
           tax = new_tax, total = subtotal + new_mgmt + new_adm + service_fee + new_tax,
           credit_applied = least(credit_applied, subtotal + new_mgmt + new_adm + service_fee + new_tax)
     where id = inv.id returning * into inv;
  end if;
  -- tersedia + cadangan invoice ini sendiri = yang boleh dipakai untuk invoice ini
  want := least(inv.total, finance.org_credit_available(inv.org_id) + inv.credit_applied);
  if p_amount is not null then
    -- diminta ≥ total (mis. total turun karena fee rollover dibebaskan) dan kredit cukup = bayar penuh
    if p_amount > want and want < inv.total then
      perform market.fail('insufficient_credit', format('kredit bisa dipakai %s, diminta %s', want, p_amount));
    end if;
    want := least(p_amount, want);
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


-- B1.8 "unduh faktur setelah lunas": admin_finance mencatat nomor faktur pajak (diterbitkan di Coretax DJP) + PDF-nya yang sudah
-- diunggah ke invoice-docs/{org_id}/{invoice_id}/…; brand_owner/brand_finance mengunduh lewat signed URL. Boleh diganti (koreksi).
create function api.attach_faktur(p_invoice uuid, p_faktur_no text, p_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  inv finance.invoices;
  no text := btrim(coalesce(p_faktur_no, ''));
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found then
    raise exception 'not_found:invoice' using errcode = 'P0002';
  end if;
  if inv.status <> 'paid' then
    raise exception 'invalid_state:%', inv.status using errcode = 'P0001';
  end if;
  if no !~ '^[0-9][0-9.-]{11,24}$' then
    raise exception 'invalid:faktur_no' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.invoices i where i.faktur_no = no and i.id <> inv.id) then
    raise exception 'faktur_used' using errcode = 'P0001';
  end if;
  if p_path is null or p_path not like inv.org_id || '/' || inv.id || '/%'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'invoice-docs' and o.name = p_path) then
    raise exception 'file_missing' using errcode = 'P0001';
  end if;
  update finance.invoices set faktur_no = no, faktur_path = p_path where id = inv.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'invoice.faktur', 'invoice:' || inv.id, jsonb_build_object('faktur_no', inv.faktur_no, 'path', inv.faktur_path),
          jsonb_build_object('faktur_no', no, 'path', p_path));
end $$;

-- Invoice top-up / pin yang belum dibayar saat campaign tak bisa berjalan lagi → void (dipanggil market.run_lifecycle).
create function finance.void_stale_addons() returns void
language sql security definer set search_path = '' as $$
  update finance.invoices i set status = 'void'
   where i.status = 'issued' and i.kind in ('topup', 'pinned')
     and exists (select 1 from market.campaigns c where c.id = i.campaign_id
                  and c.status in ('tracking', 'exhausted', 'settling', 'settled', 'cancelled', 'rejected'));
$$;
revoke execute on function finance.void_stale_addons() from public;

revoke execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text), finance.settle_invoice(finance.invoices),
  finance.org_credit_available(uuid), finance.rollover_available(uuid), api.org_credit(uuid), api.pay_invoice_with_credit(uuid, numeric),
  api.attach_faktur(uuid, text, text) from public;
grant execute on function api.confirm_invoice_payment(uuid, numeric, timestamptz, text, text), api.org_credit(uuid),
  api.pay_invoice_with_credit(uuid, numeric), api.attach_faktur(uuid, text, text) to authenticated;
