SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bridge_fulfillment_export (
  p_reward_type uuid
)
  RETURNS TABLE (
    id            uuid,
    user_id       uuid,
    amount        numeric,
    recipient     jsonb,
    recipient_ref uuid
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return query
  select f.id, f.user_id, f.amount::numeric, f.recipient, f.recipient_ref
    from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
   where f.reward_type_id = p_reward_type and f.status = 'requested' and rt.fulfillment = 'manual_export'
     and not finance.withdraw_blocked(f.user_id)
   order by f.created_at, f.id;
end $function$;

CREATE OR REPLACE FUNCTION api.request_fulfillment (
  p_reward_type   uuid,
  p_amount        numeric,
  p_recipient     jsonb,
  p_recipient_ref uuid,
  p_idempotency   text
)
  RETURNS finance.fulfillments
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f where coalesce((f ->> 'pii')::boolean, false)) then
    if p_recipient_ref is null then
      raise exception 'recipient_ref_required' using errcode = 'P0001';
    end if;
    -- C2.4/C6.1: alamat/HP hanya sampai ke brand dengan consent share_with_brand (claim JWT dari hook identity);
    -- tanpa itu klaim reward ber-PII ditolak, bukan saldo terpotong lalu tertahan di export.
    if not coalesce((select (auth.jwt() -> 'consent_ok' ->> 'share_with_brand')::boolean), false) then
      raise exception 'consent_required:share_with_brand' using errcode = 'P0001';
    end if;
  end if;
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
             where not coalesce((f ->> 'pii')::boolean, false) and coalesce((f ->> 'required')::boolean, true)
               and coalesce(rec ->> (f ->> 'key'), '') = '') then
    raise exception 'recipient_incomplete' using errcode = 'P0001';
  end if;

  if finance.withdraw_blocked(pr.id) then
    raise exception 'payout_blocked' using errcode = 'P0001';  -- R71: reward non-tunai juga nilai keluar
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
end $function$;

CREATE OR REPLACE FUNCTION api.request_payout (
  p_method      uuid,
  p_amount      numeric,
  p_channel     text,
  p_idempotency text
)
  RETURNS finance.payouts
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if finance.withdraw_blocked(pr.id) then
    raise exception 'payout_blocked' using errcode = 'P0001';
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

  -- Referral (F-C16): biasanya sudah berlaku sejak record_review KYC; cadangan bila keputusan itu tidak tercatat di core.
  update market.referrals set qualified_at = now(), bonus_until = now() + make_interval(days => bonus_days)
   where referred_id = pr.id and qualified_at is null;

  if p_channel = 'instant' then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', res.id));
  end if;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillments_due (
  p_limit integer
)
  RETURNS TABLE (
    id             uuid,
    user_id        uuid,
    reward_type_id uuid,
    amount         numeric,
    recipient      jsonb,
    fulfillment    text,
    webhook_url    text,
    webhook_secret text,
    attempts       smallint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
begin
  return query
  with due as (
    select f.id as fid from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
     where (f.status = 'requested'
            -- pool kode sempat kosong: lanjut otomatis begitu ada kode bebas lagi (S-06 on_hold → processing)
            -- (atau kodenya sudah terpasang tapi hasil kirim belum tercatat: worker mati di tengah jalan)
            or (f.status = 'on_hold' and f.last_error = 'code_pool_empty' and rt.fulfillment = 'code_pool'
                and exists (select 1 from finance.reward_codes rc where rc.reward_type_id = f.reward_type_id
                             and (rc.fulfillment_id is null or rc.fulfillment_id = f.id)))
            -- webhook macet yang dikirim ulang admin (api.retry_fulfillment: next_retry_at terisi lagi)
            or (f.status = 'on_hold' and rt.fulfillment = 'webhook' and f.next_retry_at is not null))
       and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
       and not finance.withdraw_blocked(f.user_id)  -- flag profil setelah klaim → tidak dikirim sampai direview (R71)
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    -- Lease lama masih terisi = worker sebelumnya mati sebelum mencatat hasil: kiriman itu mungkin sudah sampai ke brand.
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes', leased_until = now() + interval '5 minutes',
           delivery_uncertain = f.delivery_uncertain or f.leased_until is not null
      from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $function$;

CREATE OR REPLACE FUNCTION finance.withdraw_blocked (
  p_user uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select exists (select 1 from trust.fraud_flags f where f.target_type = 'profile' and f.target_id = p_user and f.status in ('open', 'held'));
$function$;

REVOKE ALL ON FUNCTION "finance"."withdraw_blocked"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."withdraw_blocked"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."withdraw_blocked"(uuid) TO "postgres";
