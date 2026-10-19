-- Penerbitan invoice brand (E-22, F-B04). Dipanggil save_campaign (submit → campaign; builder admin → managed_service),
-- control_campaign (topup), buy_pin (pinned). Hanya menerbitkan: pelunasan, jurnal, dan pengisian pool ada di
-- confirm_invoice_payment. Fee (§5): campaign.fee_rule_id → org.fee_rule_id → global; pajak (public.billing.tax_pct) atas fee
-- (mgmt + admin + service), dana creator = titipan (§5.4, D-01 marketplace).

-- Nomor invoice INV-YYYYMM-000123 (bulan WIB). Sequence: nomor unik walau dua transaksi bersamaan; celah nomor (rollback) wajar.
create sequence finance.invoice_number_seq;

create function finance.next_invoice_number() returns text
language sql set search_path = '' as $$
  select 'INV-' || to_char(now() at time zone 'Asia/Jakarta', 'YYYYMM') || '-'
         || lpad(nextval('finance.invoice_number_seq')::text, 6, '0');
$$;

create function finance.effective_fee_rule(p_org uuid, p_campaign uuid) returns finance.fee_rules
language sql stable set search_path = '' as $$
  select f.* from finance.fee_rules f
   where f.id = coalesce((select c.fee_rule_id from market.campaigns c where c.id = p_campaign),
                         (select o.fee_rule_id from market.organizations o where o.id = p_org),
                         (select g.id from finance.fee_rules g where g.scope = 'global'));
$$;

-- Budget creator yang dibayar tunai = Σ total pool Rupiah (reward type IDR global). Pool non-tunai (Diamonds, voucher) = stok
-- dari brand (§10.4), tidak ditagih; nilai Rp-nya hanya dasar fee (finance.noncash_value_idr, §5.2).
create function finance.campaign_budget_idr(p_campaign uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(pl.total), 0)
    from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
   where pl.campaign_id = p_campaign and rt.code = 'IDR' and rt.owner_org_id is null;
$$;

-- Nilai Rupiah yang dideklarasikan brand untuk pool non-tunai: dasar fee mgmt/admin (§5.2), bukan tagihan.
-- p_items (top-up) = [{pool_id, amount}]; NULL = semua pool campaign.
create function finance.noncash_value_idr(p_campaign uuid, p_items jsonb default null) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(coalesce((e ->> 'amount')::numeric, pl.total) * rt.idr_value_per_unit), 0)
    from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
    left join lateral jsonb_array_elements(p_items) e on (e ->> 'pool_id')::uuid = pl.id
   where pl.campaign_id = p_campaign and not (rt.code = 'IDR' and rt.owner_org_id is null)
     and (p_items is null or e is not null);
$$;

-- Bagian Rupiah (tunai) dari item top-up [{pool_id, amount}].
create function finance.topup_cash_idr(p_campaign uuid, p_items jsonb) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum((e ->> 'amount')::numeric), 0)
    from jsonb_array_elements(coalesce(p_items, '[]')) e
    join finance.reward_pools pl on pl.id = (e ->> 'pool_id')::uuid and pl.campaign_id = p_campaign
    join market.reward_types rt on rt.id = pl.reward_type_id
   where rt.code = 'IDR' and rt.owner_org_id is null;
$$;

-- Fee rule override baru (scope org/campaign) dari JSON {mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee};
-- field yang tidak diisi diambil dari rule efektif sekarang. Selalu baris baru: rule lama mungkin dipakai campaign hasil duplikat.
create function finance.create_fee_rule(p_scope text, p jsonb, p_base finance.fee_rules, p_actor uuid) returns uuid
language plpgsql set search_path = '' as $$
declare
  rid uuid;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:fee_rule', 'fee rule harus object');
  end if;
  insert into finance.fee_rules (scope, mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee, created_by)
  values (p_scope,
          coalesce(market.jnum(p -> 'mgmt_fee_pct'), p_base.mgmt_fee_pct, 15),
          coalesce(market.jnum(p -> 'admin_fee_pct'), p_base.admin_fee_pct, 5),
          coalesce(market.jnum(p -> 'clipper_fee_pct'), p_base.clipper_fee_pct, 0),
          case when p ? 'instant_withdraw_fee' then market.jnum(p -> 'instant_withdraw_fee') else p_base.instant_withdraw_fee end,
          p_actor)
  returning id into rid;
  return rid;
end $$;

-- fn:issue_invoice — subtotal = budget creator tunai (pool Rupiah; campaign/topup) atau 0 (pinned/managed_service: harga di
-- service_fee). Fee mgmt/admin = persen × (subtotal + nilai Rp deklarasi pool non-tunai) (§5.2). Top-up: subtotal & dasar fee
-- dihitung dari p_pool_topups (p_subtotal pemanggil diabaikan); campaign: p_subtotal = finance.campaign_budget_idr.
-- Notifikasi invoice.issued ke brand_owner + brand_finance (yang bisa membuka billing); payload: invoice_id, invoice_number, kind,
-- total, due_at, campaign_id, campaign_title (+ org_id, org_name dari notify_org).
create function finance.issue_invoice(p_org uuid, p_campaign uuid, p_kind text, p_subtotal numeric,
                                      p_service_fee numeric default 0, p_pin_until timestamptz default null,
                                      p_pool_topups jsonb default null)
returns finance.invoices
language plpgsql security definer set search_path = '' as $$
declare
  fr finance.fee_rules;
  sub numeric := round(coalesce(p_subtotal, 0), 2);
  svc numeric := round(coalesce(p_service_fee, 0), 2);
  mgmt numeric := 0;
  adm numeric := 0;
  base numeric;
  tx numeric;
  tax_pct numeric := coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.tax_pct'), 11);
  due_days int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.billing.invoice_due_days'), 7);
  inv finance.invoices;
begin
  if p_kind in ('campaign', 'topup') then
    fr := finance.effective_fee_rule(p_org, p_campaign);
    if fr.id is null then
      perform market.fail('config:fee_rule_missing', 'fee rule global belum ada (seed)');
    end if;
    if p_kind = 'topup' and p_pool_topups is not null then
      sub := round(finance.topup_cash_idr(p_campaign, p_pool_topups), 2);
      base := sub + finance.noncash_value_idr(p_campaign, p_pool_topups);
    else
      base := sub + case when p_kind = 'campaign' then finance.noncash_value_idr(p_campaign) else 0 end;
    end if;
    mgmt := round(base * fr.mgmt_fee_pct / 100, 2);
    adm := round(base * fr.admin_fee_pct / 100, 2);
  elsif sub <> 0 then
    perform market.fail('invalid:subtotal', 'invoice pinned/managed_service tanpa subtotal');
  end if;
  tx := round((mgmt + adm + svc) * tax_pct / 100, 2);
  insert into finance.invoices (number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, due_at,
                                pin_until, pool_topups)
  values (finance.next_invoice_number(), p_org, p_campaign, p_kind, sub, mgmt, adm, svc, tx, sub + mgmt + adm + svc + tx,
          now() + make_interval(days => due_days), p_pin_until, p_pool_topups)
  returning * into inv;
  perform market.notify_org(p_org, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.issued',
                            jsonb_build_object('invoice_id', inv.id, 'invoice_number', inv.number, 'kind', inv.kind,
                                               'total', inv.total, 'due_at', inv.due_at, 'campaign_id', inv.campaign_id,
                                               'campaign_title', (select c.title from market.campaigns c where c.id = inv.campaign_id)));
  return inv;
end $$;

revoke execute on function finance.next_invoice_number(), finance.effective_fee_rule(uuid, uuid), finance.campaign_budget_idr(uuid),
  finance.noncash_value_idr(uuid, jsonb), finance.topup_cash_idr(uuid, jsonb),
  finance.create_fee_rule(text, jsonb, finance.fee_rules, uuid),
  finance.issue_invoice(uuid, uuid, text, numeric, numeric, timestamptz, jsonb) from public;
