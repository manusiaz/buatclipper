SET local check_function_bodies = off;

ALTER TABLE "finance"."invoices"
  ADD COLUMN "fee_gross" jsonb;

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
end $function$;
