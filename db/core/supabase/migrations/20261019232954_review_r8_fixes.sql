SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.record_review (
  p_target_type text,
  p_target_id   uuid,
  p_decision    text,
  p_reason      text DEFAULT NULL::text,
  p_message     text DEFAULT NULL::text,
  p_note        text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  s record;
  is_admin boolean;
begin
  if p_target_type = 'campaign' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    select * into c from market.campaigns where id = p_target_id for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if c.status <> 'in_review' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign in_review yang bisa direview');
    end if;
    if p_decision = 'approve' then
      if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'campaign' and i.status = 'paid') then
        perform market.fail('invoice_unpaid', 'invoice campaign belum lunas');
      end if;
      update market.campaigns set status = 'scheduled' where id = c.id;
    elsif p_decision = 'reject' then
      if nullif(btrim(p_reason), '') is null then
        perform market.fail('invalid:reason', 'penolakan wajib alasan');
      end if;
      update market.campaigns set status = 'rejected' where id = c.id;
    else
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('campaign', c.id, uid, p_decision, p_reason, p_message, p_note);
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[],
                              case p_decision when 'approve' then 'campaign.approved' else 'campaign.rejected' end,
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.campaign.' || p_decision, 'campaign:' || c.id, jsonb_build_object('status', c.status),
            jsonb_build_object('status', case p_decision when 'approve' then 'scheduled' else 'rejected' end, 'reason', p_reason));

  elsif p_target_type = 'submission' then
    if p_decision not in ('approve', 'reject', 'overturn', 'uphold') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    select sb.id, sb.status, k.org_id, k.review_mode into s
      from tracking.submissions sb join market.campaigns k on k.id = sb.campaign_id where sb.id = p_target_id;
    if s.id is null then
      perform market.fail('not_found:submission', null, 'P0002');
    end if;
    is_admin := ops.has_admin('admin_moderator');
    if not is_admin and not (s.review_mode = 'brand' and s.status = 'in_review'
                             and ops.is_org_member(s.org_id, 'brand_owner', 'brand_manager')) then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2 atau brand_owner/brand_manager (review brand)', '42501');
    end if;
    perform trust.apply_submission_decision(s.id, p_decision, uid, p_reason, p_message, p_note);
    if is_admin then
      insert into ops.audit_logs (actor_id, action, target, before, after)
      values (uid, 'review.submission.' || p_decision, 'submission:' || s.id, jsonb_build_object('status', s.status),
              jsonb_build_object('status', (select x.status from tracking.submissions x where x.id = s.id), 'reason', p_reason));
    end if;

  elsif p_target_type = 'kyc' then
    -- Keputusan KYC diputus di identity (admin_kyc_decision); core hanya mencatat (tanpa PII) + mengabari user.
    if not ops.has_admin('admin_moderator') then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    if p_decision = 'reject' and nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if not exists (select 1 from market.profiles pr where pr.id = p_target_id) then
      perform market.fail('not_found:profile', null, 'P0002');
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('kyc', p_target_id, uid, p_decision, p_reason, p_message, p_note);
    -- Referral (F-C16) berlaku sejak KYC disetujui, bukan sejak withdraw pertama (earning di antaranya ikut dihitung).
    if p_decision = 'approve' then
      update market.referrals set qualified_at = now(),
             bonus_until = now() + make_interval(days => (ops.cfg('finance.referral_bonus_days', '90'))::int)
       where referred_id = p_target_id and qualified_at is null;
    end if;
    perform ops.enqueue_notification(p_target_id, case p_decision when 'approve' then 'kyc.approved' else 'kyc.rejected' end,
                                     jsonb_build_object('decision', p_decision, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.kyc.' || p_decision, 'profile:' || p_target_id, null, jsonb_build_object('reason', p_reason));

  elsif p_target_type = 'org' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    perform market.decide_org(p_target_id, p_decision, uid, p_reason, p_message, p_note);
  else
    perform market.fail('invalid:target_type', coalesce(p_target_type, 'null'));
  end if;
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

  -- Referral (F-C16): biasanya sudah berlaku sejak record_review KYC; cadangan bila keputusan itu tidak tercatat di core.
  update market.referrals set qualified_at = now(), bonus_until = now() + make_interval(days => bonus_days)
   where referred_id = pr.id and qualified_at is null;

  if p_channel = 'instant' then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', res.id));
  end if;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION market.check_rule_params (
  p_kind text,
  p      jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  t jsonb;
  prev numeric;
  n int;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:rule_params', 'params harus object');
  end if;
  if p_kind = 'per_1k_views' then
    if coalesce(market.jnum(p -> 'rate'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'per_1k_views butuh rate > 0');
    end if;
  elsif p_kind = 'flat_per_post' then
    if coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'flat_per_post butuh amount > 0');
    end if;
  elsif p_kind = 'milestone_bonus' then
    if coalesce(market.jnum(p -> 'threshold'), 0) <= 0 or coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'milestone_bonus butuh threshold & amount > 0');
    end if;
  elsif p_kind = 'tiered_cpm' then
    if jsonb_typeof(p -> 'tiers') is distinct from 'array' or jsonb_array_length(p -> 'tiers') = 0 then
      perform market.fail('invalid:rule_params', 'tiered_cpm butuh tiers [{from, to, rate}]');
    end if;
    -- Tier kontigu tanpa celah/tumpang tindih: [0, to1), [to1, to2), …; hanya tier terakhir boleh tanpa `to` (terbuka).
    -- Tumpang tindih = views yang sama dibayar dua kali oleh finance.rule_amount.
    n := jsonb_array_length(p -> 'tiers');
    for i in 0 .. n - 1 loop
      t := p -> 'tiers' -> i;
      if market.jnum(t -> 'from') is null or coalesce(market.jnum(t -> 'rate'), 0) <= 0
         or market.jnum(t -> 'from') <> (case when i = 0 then 0 else prev end)
         or (i < n - 1 and coalesce(market.jnum(t -> 'to'), 0) <= market.jnum(t -> 'from'))
         or (i = n - 1 and jsonb_typeof(t -> 'to') = 'number' and market.jnum(t -> 'to') <= market.jnum(t -> 'from'))
         -- `to` selain angka/null (mis. "1e4") lolos jnum sebagai null tapi dibaca accrual sebagai batas → tolak
         or (t ? 'to' and jsonb_typeof(t -> 'to') <> 'null' and market.jnum(t -> 'to') is null) then
        perform market.fail('invalid:rule_params', 'tier harus kontigu mulai 0 (from = to tier sebelumnya), rate > 0, hanya tier terakhir terbuka');
      end if;
      prev := market.jnum(t -> 'to');
    end loop;
  else
    perform market.fail('invalid:rule_kind', coalesce(p_kind, 'null'));
  end if;
end $function$;
