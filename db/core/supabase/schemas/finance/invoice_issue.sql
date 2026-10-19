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

-- Budget creator dalam Rupiah = Σ pool.total × nilai Rp per unit reward type (fee atas reward non-tunai, §5.2).
create function finance.campaign_budget_idr(p_campaign uuid) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(sum(pl.total * rt.idr_value_per_unit), 0)
    from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
   where pl.campaign_id = p_campaign;
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

-- fn:issue_invoice — subtotal = budget creator (campaign/topup) atau 0 (pinned/managed_service: harga di service_fee).
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
    mgmt := round(sub * fr.mgmt_fee_pct / 100, 2);
    adm := round(sub * fr.admin_fee_pct / 100, 2);
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
  finance.create_fee_rule(text, jsonb, finance.fee_rules, uuid),
  finance.issue_invoice(uuid, uuid, text, numeric, numeric, timestamptz, jsonb) from public;
