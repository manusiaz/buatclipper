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
  fee numeric := (ops.cfg('finance.refund_transfer_fee_idr', '0'))::numeric;
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
                            jsonb_build_object('refund_id', r.id, 'campaign_id', r.campaign_id, 'amount', r.amount - r.transfer_fee));
end $$;

revoke execute on function api.request_refund(uuid, uuid, text, numeric, text), api.approve_refund(uuid),
  finance.pay_refund(uuid, text) from public;
grant execute on function api.request_refund(uuid, uuid, text, numeric, text), api.approve_refund(uuid) to authenticated;
