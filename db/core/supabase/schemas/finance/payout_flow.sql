-- Withdraw Rupiah (F-C09/F-C15, alur 3 & 11) dan klaim reward non-tunai (F-C09, S-06). Jurnal:
--   request_payout     : wallet available −amount → wallet withdrawn +(amount − fee) + platform_revenue +fee (fee instant, REV-5)
--   gagal/dikembalikan : kebalikannya (ref_type payout_return), saldo kembali ke Tersedia termasuk fee
--   request_fulfillment: wallet available → withdrawn (ref_type fulfillment)
-- amount = yang dipotong dari Tersedia; yang ditransfer = amount − fee (constraint payouts_fee_below_amount).

-- Syarat bersama fungsi uang clipper: sesi identity + profil aktif (suspend yang sudah lewat masa dianggap aktif).
create function finance.require_active_clipper() returns market.profiles
language plpgsql security definer set search_path = '' as $$
declare
  pr market.profiles;
begin
  if (select auth.uid()) is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  select * into pr from market.profiles where id = (select auth.uid());
  if not found or not (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now())) then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  return pr;
end $$;

create function api.request_payout(p_method uuid, p_amount numeric, p_channel text, p_idempotency text)
returns finance.payouts
language plpgsql security definer set search_path = '' as $$
declare
  pr market.profiles := finance.require_active_clipper();
  idr uuid := finance.idr();
  res finance.payouts;
  wallet uuid;
  fee numeric := 0;
  bonus_days int := (ops.cfg('finance.referral_bonus_days', '90'))::int;
begin
  if coalesce(auth.jwt() ->> 'kyc', '') <> 'approved' then
    raise exception 'auth:kyc_required' using errcode = '42501';
  end if;
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  select * into res from finance.payouts p where p.idempotency_key = p_idempotency;
  if found then
    if res.user_id <> pr.id then
      raise exception 'idempotency_conflict' using errcode = 'P0001';
    end if;
    return res;  -- replay: tidak memotong saldo dua kali
  end if;
  if p_method is null then
    raise exception 'invalid:method' using errcode = 'P0001';
  end if;
  if p_channel is null or p_channel not in ('batch', 'instant') then
    raise exception 'invalid:channel' using errcode = 'P0001';
  end if;
  if exists (select 1 from trust.fraud_flags f where f.target_type = 'profile' and f.target_id = pr.id and f.status in ('open', 'held')) then
    raise exception 'payout_blocked' using errcode = 'P0001';  -- FR-04/FR-05: blok withdraw sampai direview
  end if;
  if p_amount is null or p_amount <> trunc(p_amount) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  if p_amount < (ops.cfg('public.finance.min_withdraw_idr', '100000'))::numeric then
    raise exception 'below_minimum' using errcode = 'P0001';
  end if;
  if p_channel = 'instant' then
    if not coalesce((ops.cfg('public.flags.instant_withdraw', 'false'))::boolean, false) then
      raise exception 'instant_disabled' using errcode = 'P0001';
    end if;
    if pr.trust_score < (ops.cfg('public.finance.instant_min_trust', '70'))::int then
      raise exception 'trust_too_low' using errcode = 'P0001';
    end if;
    fee := coalesce((select fr.instant_withdraw_fee from finance.fee_rules fr where fr.scope = 'global'), 0);
    if fee >= p_amount then
      raise exception 'below_minimum' using errcode = 'P0001';
    end if;
  end if;

  wallet := finance.account('user_wallet', pr.id, idr);
  perform 1 from finance.ledger_accounts a where a.id = wallet for update;  -- serialkan withdraw per user
  if finance.balance(wallet, 'available') < p_amount then
    raise exception 'insufficient_balance' using errcode = 'P0001';
  end if;

  insert into finance.payouts (user_id, method_id, amount, fee, channel, idempotency_key)
  values (pr.id, p_method, p_amount, fee, p_channel, p_idempotency) returning * into res;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -p_amount, 'payout', res.id::text, 'available'),
    finance.e(wallet, p_amount - fee, 'payout', res.id::text, 'withdrawn'),
    finance.e(finance.account('platform_revenue', null, idr), fee, 'fee', res.id::text)));

  -- Referral (F-C16) mulai berlaku saat core pertama kali melihat KYC approved user ini.
  update market.referrals set qualified_at = now(), bonus_until = now() + make_interval(days => bonus_days)
   where referred_id = pr.id and qualified_at is null;

  if p_channel = 'instant' then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', res.id));
  end if;
  return res;
end $$;

-- Kembalikan dana payout gagal (S-05 processing → failed → returned) ke Tersedia, termasuk fee instant.
create function finance.return_payout(p_payout uuid, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  po finance.payouts;
  idr uuid := finance.idr();
  wallet uuid;
begin
  select * into po from finance.payouts p where p.id = p_payout for update;
  if po.status = 'returned' then
    return;
  end if;
  if po.status = 'processing' then
    update finance.payouts set status = 'failed' where id = po.id;
  end if;
  update finance.payouts set status = 'returned' where id = po.id;  -- trigger S-05 menolak kalau bukan dari failed
  wallet := finance.account('user_wallet', po.user_id, idr);
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -(po.amount - po.fee), 'payout_return', po.id::text, 'withdrawn'),
    finance.e(finance.account('platform_revenue', null, idr), -po.fee, 'payout_return', po.id::text),
    finance.e(wallet, po.amount, 'payout_return', po.id::text, 'available')));
  perform ops.enqueue_notification(po.user_id, 'payout.failed',
                                   jsonb_build_object('payout_id', po.id, 'amount', po.amount, 'channel', po.channel));
  perform ops.raise_alert('payout.failed', 'warning', jsonb_build_object('payout_id', po.id, 'channel', po.channel,
                                                                           'amount', po.amount, 'error', left(p_error, 500)));
end $$;

create function api.create_payout_batch(p_cutoff timestamptz) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  bid uuid;
  n int;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  insert into finance.payout_batches (created_by, cutoff_at) values ((select auth.uid()), coalesce(p_cutoff, now()))
  returning id into bid;
  update finance.payouts set batch_id = bid
   where status = 'requested' and channel = 'batch' and batch_id is null and created_at <= coalesce(p_cutoff, now());
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'batch_empty' using errcode = 'P0001';
  end if;
  update finance.payout_batches b set count = n,
         total = (select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = bid)
   where b.id = bid;
  return bid;
end $$;

-- Aturan dua orang: approved_by ≠ created_by ditegakkan constraint payout_batches_two_person (23514).
create function api.approve_payout_batch(p_batch uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.payout_batches set approved_by = (select auth.uid()), status = 'approved'
   where id = p_batch and status = 'draft';
  if not found then
    raise exception 'batch_not_draft' using errcode = 'P0001';
  end if;
end $$;

-- p_results: [{payout_id, status: paid|failed, bank_ref}]. Hanya payout yang masuk CSV (status processing, alur 3).
-- Replay hasil yang sama = no-op. Batch → paid setelah tidak ada payout processing tersisa.
create function api.mark_batch_paid(p_batch uuid, p_results jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found or b.status not in ('exported', 'paid', 'closed') then
    raise exception 'batch_not_exported' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception 'invalid:results' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' then
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = x.bank_ref where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', jsonb_build_object('payout_id', po.id, 'amount', po.amount - po.fee));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id);
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
end $$;

-- Klaim reward non-tunai. recipient_schema reward type = [{key, pii, required}]: field pii tidak boleh ada di p_recipient
-- (nilainya di identity E-29, wajib recipient_ref); field non-pii yang required wajib diisi. code_pool: 1 kode = 1 klaim.
create function api.request_fulfillment(p_reward_type uuid, p_amount numeric, p_recipient jsonb, p_recipient_ref uuid,
                                        p_idempotency text)
returns finance.fulfillments
language plpgsql security definer set search_path = '' as $$
declare
  pr market.profiles := finance.require_active_clipper();
  rt market.reward_types;
  res finance.fulfillments;
  wallet uuid;
  rec jsonb := coalesce(p_recipient, '{}');
begin
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  select * into res from finance.fulfillments f where f.idempotency_key = p_idempotency;
  if found then
    if res.user_id <> pr.id then
      raise exception 'idempotency_conflict' using errcode = 'P0001';
    end if;
    return res;
  end if;
  select * into rt from market.reward_types t where t.id = p_reward_type;
  if not found or rt.fulfillment = 'payout' then
    raise exception 'invalid:reward_type' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount, rt.decimals)
     or (rt.fulfillment = 'code_pool' and p_amount <> 1) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  if jsonb_typeof(rec) <> 'object' then
    raise exception 'invalid:recipient' using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
             where coalesce((f ->> 'pii')::boolean, false) and rec ? (f ->> 'key')) then
    raise exception 'pii_in_recipient' using errcode = 'P0001';
  end if;
  if p_recipient_ref is null and exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
                                         where coalesce((f ->> 'pii')::boolean, false)) then
    raise exception 'recipient_ref_required' using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
             where not coalesce((f ->> 'pii')::boolean, false) and coalesce((f ->> 'required')::boolean, true)
               and coalesce(rec ->> (f ->> 'key'), '') = '') then
    raise exception 'recipient_incomplete' using errcode = 'P0001';
  end if;

  wallet := finance.account('user_wallet', pr.id, rt.id);
  perform 1 from finance.ledger_accounts a where a.id = wallet for update;
  if finance.balance(wallet, 'available') < p_amount then
    raise exception 'insufficient_balance' using errcode = 'P0001';
  end if;
  insert into finance.fulfillments (user_id, reward_type_id, amount, recipient, recipient_ref, idempotency_key)
  values (pr.id, rt.id, p_amount, rec, p_recipient_ref, p_idempotency) returning * into res;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -p_amount, 'fulfillment', res.id::text, 'available'),
    finance.e(wallet, p_amount, 'fulfillment', res.id::text, 'withdrawn')));
  return res;
end $$;

revoke execute on function finance.require_active_clipper(), finance.return_payout(uuid, text),
  api.request_payout(uuid, numeric, text, text), api.create_payout_batch(timestamptz), api.approve_payout_batch(uuid),
  api.mark_batch_paid(uuid, jsonb), api.request_fulfillment(uuid, numeric, jsonb, uuid, text) from public;
grant execute on function api.request_payout(uuid, numeric, text, text), api.create_payout_batch(timestamptz),
  api.approve_payout_batch(uuid), api.mark_batch_paid(uuid, jsonb), api.request_fulfillment(uuid, numeric, jsonb, uuid, text)
  to authenticated;
