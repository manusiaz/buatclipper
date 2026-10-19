-- Sisa budget creator (D-09, F-B04). Sisa = saldo akun campaign_pool Rupiah campaign yang settled/cancelled (ledger, bukan
-- cache allocated). Jurnal:
--   rollover : campaign_pool → org_credit (ref_type rollover, ref_id = idempotency key); kredit dipakai campaign berikutnya
--   refund   : campaign_pool → org_credit (ref_type refund, ref_id = id E-35) saat diajukan, jadi sisa tidak bisa dua kali
--              ditarik; saat dibayar (bukti transfer, bridge_attach_proof) org_credit → bank_clearing (amount − biaya transfer)
--              + platform_revenue (biaya transfer).
create function api.request_refund(p_org uuid, p_campaign uuid, p_mode text, p_amount numeric, p_idempotency text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  idr uuid := finance.idr();
  c market.campaigns;
  credit uuid;
  rid uuid;
  left_total numeric := 0;
  need numeric;
  take numeric;
  ref text;
  x record;
  entries jsonb := '[]';
  fee numeric := (ops.cfg('public.finance.refund_transfer_fee_idr', '0'))::numeric;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  if not ops.is_org_member(p_org, 'brand_owner', 'brand_finance') or coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('rollover', 'refund') then
    raise exception 'invalid:mode' using errcode = 'P0001';
  end if;
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  -- Replay: kembalikan hasil yang sama tanpa jurnal baru.
  if p_mode = 'refund' then
    select r.id into rid from finance.org_refunds r where r.idempotency_key = p_idempotency and r.org_id = p_org;
    if rid is not null then
      return rid;
    end if;
  else
    select e.txn_id into rid from finance.ledger_entries e where e.ref_type = 'rollover' and e.ref_id = p_idempotency limit 1;
    if rid is not null then
      return rid;
    end if;
  end if;

  select * into c from market.campaigns k where k.id = p_campaign and k.org_id = p_org;
  if not found then
    raise exception 'not_found:campaign' using errcode = 'P0002';
  end if;
  if c.status not in ('settled', 'cancelled') then
    raise exception 'invalid_state:%', c.status using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) or (p_mode = 'refund' and p_amount <= fee) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  perform 1 from finance.reward_pools rp where rp.campaign_id = c.id order by rp.id for update;
  select coalesce(sum(finance.balance(a.id)), 0) into left_total
    from finance.reward_pools rp join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
   where rp.campaign_id = c.id and rp.reward_type_id = idr;
  if p_amount > left_total then
    raise exception 'insufficient_balance' using errcode = 'P0001', detail = format('sisa %s', left_total);
  end if;

  if p_mode = 'refund' then
    insert into finance.org_refunds (org_id, campaign_id, amount, transfer_fee, requested_by, idempotency_key)
    values (p_org, c.id, p_amount, fee, uid, p_idempotency) returning id into rid;
    ref := rid::text;
  else
    rid := gen_random_uuid();  -- txn id rollover
    ref := p_idempotency;
  end if;
  need := p_amount;
  for x in select a.id as account, finance.balance(a.id) as bal
             from finance.reward_pools rp join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
            where rp.campaign_id = c.id and rp.reward_type_id = idr order by rp.id loop
    exit when need <= 0;
    take := least(need, greatest(x.bal, 0));
    entries := entries || jsonb_build_array(finance.e(x.account, -take, p_mode, ref));
    need := need - take;
  end loop;
  credit := finance.account('org_credit', p_org, idr);
  entries := entries || jsonb_build_array(finance.e(credit, p_amount, p_mode, ref));
  perform finance.post(case when p_mode = 'rollover' then rid else gen_random_uuid() end, entries);
  return rid;
end $$;

-- Persetujuan refund oleh admin_finance (aal2); dua orang: approved_by ≠ requested_by (constraint org_refunds_two_person).
create function api.approve_refund(p_refund uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.org_refunds set status = 'approved', approved_by = (select auth.uid()) where id = p_refund and status = 'requested';
  if not found then
    raise exception 'invalid_state:refund' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'refund.approve', 'refund:' || p_refund, '{"status": "requested"}', '{"status": "approved"}');
end $$;

-- Refund dibayar (dipanggil bridge_attach_proof setelah bukti transfer diunggah di identity).
create function finance.pay_refund(p_refund uuid, p_proof_ref text) returns void
language plpgsql security definer set search_path = '' as $$
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
  update finance.org_refunds set status = 'paid', paid_at = now(), proof_ref = p_proof_ref where id = r.id;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(finance.account('org_credit', r.org_id, idr), -r.amount, 'refund', r.id || ':paid'),
    finance.e(finance.account('bank_clearing', null, idr), r.amount - r.transfer_fee, 'refund', r.id || ':paid'),
    finance.e(finance.account('platform_revenue', null, idr), r.transfer_fee, 'refund', r.id || ':paid')));
  perform market.notify_org(r.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.paid',
                            market.campaign_ref(r.campaign_id) || finance.amount_ref(idr, r.amount - r.transfer_fee)
                            || jsonb_build_object('refund_id', r.id, 'transfer_fee', r.transfer_fee));
end $$;

-- D-09 batal sebelum live (draft/in_review/scheduled → cancelled, lewat control_campaign atau jalur admin mana pun): semua yang
-- sudah dibayar untuk campaign (invoice campaign, topup, pinned: budget + fee + pajak; tanpa payment gateway jadi tanpa potongan)
-- dikembalikan lewat satu refund E-35 requested, lalu ikut alur approve → bukti transfer biasa. Satu transaksi, idempoten
-- (idempotency_key 'cancel:<campaign>'). Jurnal (ref_type refund, ref_id = id E-35):
--   campaign_pool(IDR) −saldo, platform_revenue −fee, tax_payable −pajak → org_credit +total (dibayar keluar saat pay_refund);
--   stok non-tunai kembali ke brand: campaign_pool(rt) −saldo → bank_clearing(rt) +saldo.
-- Invoice managed_service tidak ikut: jasa penyusunan sudah diserahkan saat invoice terbit. Invoice issued di-void.
create function finance.refund_cancelled_campaign(p_campaign uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
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
    from finance.invoices i where i.campaign_id = c.id and i.status = 'paid' and i.kind in ('campaign', 'topup', 'pinned');
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
end $$;

create function finance.on_campaign_cancelled() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform finance.refund_cancelled_campaign(new.id);
  return null;
end $$;
create trigger campaigns_cancel_refund after update of status on market.campaigns
  for each row when (new.status = 'cancelled' and old.status is distinct from new.status)
  execute function finance.on_campaign_cancelled();

revoke execute on function api.request_refund(uuid, uuid, text, numeric, text), api.approve_refund(uuid),
  finance.pay_refund(uuid, text), finance.refund_cancelled_campaign(uuid), finance.on_campaign_cancelled() from public;
grant execute on function api.request_refund(uuid, uuid, text, numeric, text), api.approve_refund(uuid) to authenticated;
