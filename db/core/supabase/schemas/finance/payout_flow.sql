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

-- Jurnal kebalikan request_payout: withdrawn −(amount − fee), platform_revenue −fee, available +amount. ref_id = id payout,
-- jadi unique ledger menjamin satu payout hanya dikembalikan sekali (returned atau cancelled, dua-duanya final).
create function finance.unwind_payout_journal(po finance.payouts) returns void
language plpgsql security definer set search_path = '' as $$
declare
  idr uuid := finance.idr();
  wallet uuid := finance.account('user_wallet', po.user_id, idr);
begin
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -(po.amount - po.fee), 'payout_return', po.id::text, 'withdrawn'),
    finance.e(finance.account('platform_revenue', null, idr), -po.fee, 'payout_return', po.id::text),
    finance.e(wallet, po.amount, 'payout_return', po.id::text, 'available')));
end $$;

-- Kembalikan dana payout gagal ke Tersedia, termasuk fee instant: S-05 processing/paid → failed → returned. paid → failed =
-- transfer dibalik setelah sukses (REVERSED penyedia / retur bank). Idempoten: payout returned tidak dijurnal lagi.
create function finance.return_payout(p_payout uuid, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  po finance.payouts;
  idr uuid := finance.idr();
begin
  select * into po from finance.payouts p where p.id = p_payout for update;
  if po.status = 'returned' then
    return;
  end if;
  if po.status in ('processing', 'paid') then
    update finance.payouts set status = 'failed', last_error = left(p_error, 500) where id = po.id;
  end if;
  update finance.payouts set status = 'returned' where id = po.id;  -- trigger S-05 menolak kalau bukan dari failed
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.failed', finance.amount_ref(idr, po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', left(p_error, 200)));
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
  insert into ops.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'payout_batch.create', 'payout_batch:' || bid,
          (select jsonb_build_object('count', b.count, 'total', b.total, 'cutoff', p_cutoff) from finance.payout_batches b where b.id = bid));
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
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.approve', 'payout_batch:' || p_batch, '{"status": "draft"}', '{"status": "approved"}');
end $$;

-- p_results: [{payout_id, status: paid|failed, bank_ref, reason?}] (reason → payouts.last_error). Hanya payout yang masuk CSV (alur 3).
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
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text, reason text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' and not (po.status = 'paid' and x.status = 'failed') then  -- paid → failed = retur bank
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = x.bank_ref where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', finance.amount_ref(finance.idr(), po.amount - po.fee)
                                       || jsonb_build_object('payout_id', po.id, 'channel', po.channel));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id, coalesce(nullif(btrim(x.reason), ''), 'transfer gagal (batch)'));
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.mark_paid', 'payout_batch:' || p_batch, jsonb_build_object('status', b.status),
          jsonb_build_object('results', p_results));
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

-- Batalkan payout yang ditahan (S-05 on_hold → cancelled; batch yang belum diekspor: requested → on_hold → cancelled) oleh
-- admin_finance (aal2): dana + fee kembali ke Tersedia. Instant requested tidak bisa dibatalkan (mungkin sedang diproses
-- penyedia) — tahan dulu lewat fraud queue. Idempoten.
create function api.cancel_payout(p_payout uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status = 'cancelled' then
    return;
  end if;
  if not (po.status = 'on_hold' or (po.status = 'requested' and po.channel = 'batch')) then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  -- Batch approved = isi CSV transfer sedang/akan dibaca identity (get_batch → attach_export): payout requested di dalamnya
  -- tidak boleh dibatalkan, kalau tidak dananya kembali ke Tersedia sekaligus ikut ditransfer. FOR SHARE: serial dengan approve.
  if po.status = 'requested'
     and exists (select 1 from finance.payout_batches b where b.id = po.batch_id and b.status <> 'draft' for share) then
    raise exception 'invalid_state:batch_locked' using errcode = 'P0001',
      detail = 'batch sudah disetujui; tandai gagal setelah export bila perlu';
  end if;
  if po.status = 'requested' then
    update finance.payouts set status = 'on_hold', hold_reason = p_reason where id = po.id;
  end if;
  update finance.payouts set status = 'cancelled', hold_reason = p_reason where id = po.id;
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.cancelled', finance.amount_ref(finance.idr(), po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.cancel', 'payout:' || po.id, jsonb_build_object('status', po.status),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason));
end $$;

-- Batalkan/kembalikan klaim reward non-tunai (S-06): requested → on_hold → cancelled, on_hold → cancelled,
-- processing → failed → returned, failed → returned. Saldo kembali ke Tersedia (ref_type fulfillment, ref_id '<id>:return').
-- Kode voucher yang sudah terpasang = sudah terlihat clipper → tidak bisa dibatalkan. admin_ops/admin_finance (aal2).
create function api.cancel_fulfillment(p_fulfillment uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  f finance.fulfillments;
  wallet uuid;
begin
  if not ops.has_admin('admin_ops', 'admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status in ('cancelled', 'returned') then
    return;
  end if;
  if f.status = 'delivered' then
    raise exception 'invalid_state:delivered' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.reward_codes rc where rc.fulfillment_id = f.id) then
    raise exception 'code_assigned' using errcode = 'P0001';
  end if;
  if f.status = 'requested' then
    update finance.fulfillments set status = 'on_hold' where id = f.id;
  elsif f.status = 'processing' then
    update finance.fulfillments set status = 'failed' where id = f.id;
  end if;
  update finance.fulfillments set status = case when f.status in ('requested', 'on_hold') then 'cancelled' else 'returned' end
                                           ::finance.fulfillment_status,
         last_error = p_reason, next_retry_at = null
   where id = f.id;
  wallet := finance.account('user_wallet', f.user_id, f.reward_type_id);
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -f.amount, 'fulfillment', f.id || ':return', 'withdrawn'),
    finance.e(wallet, f.amount, 'fulfillment', f.id || ':return', 'available')));
  perform ops.enqueue_notification(f.user_id, 'fulfillment.cancelled', finance.amount_ref(f.reward_type_id, f.amount)
                                   || jsonb_build_object('fulfillment_id', f.id, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'fulfillment.cancel', 'fulfillment:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('reason', p_reason));
end $$;

-- Instant yang macet (alur 11): requested/processing tanpa provider_ref > 15 menit → bridge disburse dipanggil ulang (aman: idempotency
-- key penyedia = id payout). Macet > 1 jam → alert. Dipanggil job lifecycle.
create function finance.retry_instant_payouts() returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  old int := 0;
begin
  for r in select p.id, p.created_at from finance.payouts p
            where p.channel = 'instant' and p.status in ('requested', 'processing') and p.provider_ref is null
              and p.created_at <= now() - interval '15 minutes'
            order by p.created_at limit 200 loop
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', r.id));
    n := n + 1;
    if r.created_at <= now() - interval '1 hour' then
      old := old + 1;
    end if;
  end loop;
  if old > 0 then
    perform ops.raise_alert('payout.instant_stuck', 'warning', jsonb_build_object('count', old), interval '6 hours');
  end if;
  return n;
end $$;

revoke execute on function finance.require_active_clipper(), finance.return_payout(uuid, text), finance.retry_instant_payouts(),
  finance.unwind_payout_journal(finance.payouts), api.cancel_payout(uuid, text), api.cancel_fulfillment(uuid, text),
  api.request_payout(uuid, numeric, text, text), api.create_payout_batch(timestamptz), api.approve_payout_batch(uuid),
  api.mark_batch_paid(uuid, jsonb), api.request_fulfillment(uuid, numeric, jsonb, uuid, text) from public;
grant execute on function api.request_payout(uuid, numeric, text, text), api.create_payout_batch(timestamptz),
  api.cancel_payout(uuid, text), api.cancel_fulfillment(uuid, text),
  api.approve_payout_batch(uuid), api.mark_batch_paid(uuid, jsonb), api.request_fulfillment(uuid, numeric, jsonb, uuid, text)
  to authenticated;
