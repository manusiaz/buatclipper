SET local check_function_bodies = off;

DROP POLICY "invoices_finance_read" ON "finance"."invoices";

DROP VIEW "api"."campaigns";

DROP VIEW "api"."organizations";

ALTER TABLE "finance"."invoices"
  DROP CONSTRAINT "invoices_payment_channel_check";

CREATE OR REPLACE FUNCTION api.confirm_invoice_payment (
  p_invoice uuid,
  p_amount  numeric,
  p_paid_at timestamp with time zone,
  p_ref     text,
  p_channel text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if p_amount is distinct from inv.total then
    raise exception 'amount_mismatch' using errcode = 'P0001', detail = format('invoice %s, dibayar %s', inv.total, p_amount);
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
  perform finance.settle_invoice(inv, finance.account('bank_clearing', null, finance.idr()));
end $function$;

CREATE OR REPLACE FUNCTION api.create_report_link (
  p_campaign uuid,
  p_days     integer DEFAULT 90
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  org uuid;
  tok text;
begin
  if not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  select c.org_id into org from market.campaigns c where c.id = p_campaign;
  if org is null or not ops.is_org_member(org, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'hanya brand_owner atau brand_manager org ini', '42501');
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.report_links (campaign_id, token_hash, created_by, expires_at)
  values (p_campaign, sha256(convert_to(tok, 'UTF8')), (select auth.uid()),
          case when p_days is not null then now() + make_interval(days => p_days) end);
  return tok;
end $function$;

CREATE OR REPLACE FUNCTION api.manage_user (
  p_user   uuid,
  p_action text,
  p_params jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  pr market.profiles;
  delta int;
  days int;
begin
  if not ops.has_admin('admin_ops', 'admin_moderator') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_moderator aal2', '42501');
  end if;
  select * into pr from market.profiles where id = p_user for update;
  if pr.id is null then
    perform market.fail('not_found:profile', null, 'P0002');
  end if;
  if nullif(btrim(coalesce(prm ->> 'reason', prm ->> 'note')), '') is null then
    perform market.fail('invalid:reason', 'aksi admin atas user wajib alasan');
  end if;
  if p_action = 'trust_override' then
    delta := market.jnum(prm -> 'delta')::int;
    if delta is null or delta = 0 or delta not between -100 and 100 then
      perform market.fail('invalid:delta', 'delta -100..100, bukan 0');
    end if;
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (pr.id, delta, 'admin_override', left(prm ->> 'note', 200), uid);
    update market.profiles set trust_score = least(100, greatest(0, 50 + (select coalesce(sum(e.delta), 0) from trust.score_events e
                                                                           where e.user_id = pr.id)))
     where id = pr.id;
  elsif p_action = 'suspend' then
    days := market.jnum(prm -> 'days')::int;
    if days is null or days not between 1 and 365 then
      perform market.fail('invalid:days', 'suspend 1–365 hari');
    end if;
    if pr.status not in ('active', 'suspended') then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'suspended', suspended_until = now() + make_interval(days => days) where id = pr.id;
    update market.claims set status = 'released' where user_id = pr.id and status = 'open';
    perform ops.enqueue_notification(pr.id, 'account.suspended',
                                     jsonb_build_object('until', now() + make_interval(days => days), 'reason', prm ->> 'reason'));
  elsif p_action = 'unsuspend' then
    if pr.status <> 'suspended' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id;
  else
    perform market.fail('invalid:action', p_action);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'user.' || p_action, 'profile:' || pr.id,
          jsonb_build_object('status', pr.status, 'trust_score', pr.trust_score, 'suspended_until', pr.suspended_until),
          prm || jsonb_build_object('status', (select p.status from market.profiles p where p.id = pr.id),
                                    'trust_score', (select p.trust_score from market.profiles p where p.id = pr.id)));
end $function$;

CREATE OR REPLACE FUNCTION api.mark_fulfillment_delivered (
  p_fulfillment uuid,
  p_ref         text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  f finance.fulfillments;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if f.id is null then
    perform market.fail('not_found:fulfillment', null, 'P0002');
  end if;
  if (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'manual_export' then
    perform market.fail('invalid:fulfillment', 'hanya reward manual_export yang ditandai manual');
  end if;
  if f.status = 'delivered' then
    return;
  end if;
  if f.status not in ('requested', 'on_hold', 'processing') then
    perform market.fail('invalid_state:' || f.status);
  end if;
  if nullif(btrim(p_ref), '') is null then
    perform market.fail('invalid:ref', 'referensi kiriman wajib');
  end if;
  perform api.worker_fulfillment_result(f.id, true, left(btrim(p_ref), 200), null);
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fulfillment.deliver', 'fulfillment:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('status', 'delivered', 'ref', left(btrim(p_ref), 200)));
end $function$;

CREATE OR REPLACE FUNCTION api.org_credit (
  p_org uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
    'available', trim_scale(case when acc is null then 0 else finance.org_credit_available(p_org) end),
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
end $function$;

CREATE OR REPLACE FUNCTION api.pay_invoice_with_credit (
  p_invoice uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  inv finance.invoices;
begin
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found or not ops.is_org_member(inv.org_id, 'brand_owner', 'brand_finance') then
    perform market.fail('not_found:invoice', null, 'P0002');
  end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    perform market.fail('auth:mfa_required', 'aksi uang brand butuh aal2', '42501');
  end if;
  if inv.status = 'paid' and inv.payment_ref = 'credit:' || inv.id then
    return;
  end if;
  if inv.status <> 'issued' then
    perform market.fail('invalid_state:' || inv.status);
  end if;
  if inv.kind = 'campaign' and exists (select 1 from finance.invoices i where i.campaign_id = inv.campaign_id and i.kind = 'campaign'
                                                                        and i.status = 'paid') then
    perform market.fail('campaign_already_funded');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('org_credit:' || inv.org_id, 0));
  if finance.org_credit_available(inv.org_id) < inv.total then
    perform market.fail('insufficient_credit', format('kredit %s, invoice %s', finance.org_credit_available(inv.org_id), inv.total));
  end if;
  update finance.invoices set status = 'paid', payment_channel = 'credit', payment_ref = 'credit:' || inv.id, paid_amount = inv.total,
         paid_at = now(), confirmed_by = uid
   where id = inv.id;
  perform finance.settle_invoice(inv, finance.account('org_credit', inv.org_id, finance.idr()));
end $function$;

CREATE OR REPLACE FUNCTION api.request_refund (
  p_org         uuid,
  p_campaign    uuid,
  p_mode        text,
  p_amount      numeric,
  p_idempotency text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.revoke_report_link (
  p_link uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  update market.report_links rl set revoked_at = now()
   where rl.id = p_link and rl.revoked_at is null
     and exists (select 1 from market.campaigns c where c.id = rl.campaign_id
                 and ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager'));
  if not found then
    perform market.fail('auth:forbidden', 'link tidak ada atau bukan milik org-mu', '42501');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.upload_reward_codes (
  p_reward_type uuid,
  p_codes       text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  rt market.reward_types;
  n int;
begin
  select * into rt from market.reward_types where id = p_reward_type;
  if rt.id is null then
    perform market.fail('not_found:reward_type', null, 'P0002');
  end if;
  -- Brand pemilik reward type, atau admin_ops (F-A10: kode dari brand dikirim ke tim, atau reward type milik platform).
  if not (ops.has_admin('admin_ops')
          or (rt.owner_org_id is not null and ops.is_org_member(rt.owner_org_id, 'brand_owner', 'brand_manager'))) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager pemilik reward type atau admin_ops', '42501');
  end if;
  if rt.fulfillment <> 'code_pool' then
    perform market.fail('invalid:fulfillment', 'reward type ini bukan pool kode');
  end if;
  if coalesce(cardinality(p_codes), 0) > 10000 then
    perform market.fail('invalid:codes', 'maks 10.000 kode per unggahan');
  end if;
  insert into finance.reward_codes (reward_type_id, code, uploaded_by)
  select rt.id, x.code, uid from (select distinct btrim(u) as code from unnest(p_codes) u where btrim(u) <> '') x
  on conflict (reward_type_id, code) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION finance.org_credit_available (
  p_org uuid
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select finance.balance(finance.account('org_credit', p_org, finance.idr()))
         - coalesce((select sum(r.amount) from finance.org_refunds r where r.org_id = p_org and r.status in ('requested', 'approved')), 0);
$function$;

CREATE OR REPLACE FUNCTION finance.release_earnings()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  hold int := (ops.cfg('public.finance.hold_days', '7'))::int;
  s record;
  g record;
  wallet uuid;
  avail numeric;
  entries jsonb;
  released jsonb;
begin
  for s in select t.id, t.user_id, t.campaign_id from tracking.submissions t
            where t.status = 'locked' and t.locked_at <= now() - make_interval(days => hold)
              and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held')
                              and ((f.target_type = 'submission' and f.target_id = t.id)
                                or (f.target_type = 'profile' and f.target_id = t.user_id)
                                or (f.target_type = 'social_account' and f.target_id = t.social_account_id)))
              and not exists (select 1 from finance.clip_earnings ce where ce.submission_id = t.id and ce.demand > 0)
            order by t.locked_at limit 1000
            for update of t skip locked loop
    entries := '[]';
    released := '{}';
    perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
    for g in select ce.pool_id, rp.reward_type_id, rt.code, rt.decimals, sum(ce.amount) as amount
               from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
               join market.reward_types rt on rt.id = rp.reward_type_id
              where ce.submission_id = s.id and ce.released_at is null
              group by ce.pool_id, rp.reward_type_id, rt.code, rt.decimals having sum(ce.amount) > 0
              order by ce.pool_id loop
      wallet := finance.account('user_wallet', s.user_id, g.reward_type_id);
      avail := trunc(g.amount, g.decimals);
      entries := entries || jsonb_build_array(
        finance.e(wallet, -g.amount, 'release', s.id || ':' || g.pool_id, 'pending'),
        finance.e(wallet, avail, 'release', s.id || ':' || g.pool_id, 'available'),
        finance.e(finance.account('campaign_pool', g.pool_id, g.reward_type_id), g.amount - avail, 'release', s.id || ':' || g.pool_id));
      if g.amount > avail then
        update finance.reward_pools set allocated = allocated - (g.amount - avail) where id = g.pool_id;
      end if;
      if avail > 0 then
        released := released || jsonb_build_object(g.reward_type_id::text,
                                                    coalesce((released ->> g.reward_type_id::text)::numeric, 0) + avail);
      end if;
    end loop;
    update finance.clip_earnings set released_at = now() where submission_id = s.id and released_at is null;
    update tracking.submissions set status = 'settled' where id = s.id;
    perform finance.post(gen_random_uuid(), entries);
    if released <> '{}' then
      perform ops.enqueue_notification(s.user_id, 'earning.available', market.campaign_ref(s.campaign_id) || jsonb_build_object(
        'submission_id', s.id,
        'amounts', (select jsonb_agg(finance.amount_ref(x.key::uuid, x.value::numeric)) from jsonb_each_text(released) x)));
    end if;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION finance.settle_invoice (
  inv      finance.invoices,
  p_source uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  idr uuid := finance.idr();
  entries jsonb := '[]';
  pool_idr numeric := 0;
  revenue numeric;
  x record;
begin
  entries := jsonb_build_array(finance.e(p_source, -inv.total, 'invoice_payment', inv.id::text),
                               finance.e(finance.account('tax_payable', null, idr), inv.tax, 'invoice_payment', inv.id::text));
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

  if inv.kind = 'pinned' then
    update market.campaigns set pinned_until = greatest(coalesce(pinned_until, inv.pin_until), inv.pin_until)
     where id = inv.campaign_id;
  end if;
  perform market.notify_org(inv.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.paid',
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, inv.total)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $function$;

CREATE OR REPLACE FUNCTION trust.auto_approve_overdue()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'public.market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $function$;

ALTER TABLE "finance"."invoices"
  ADD CONSTRAINT "invoices_payment_channel_check" CHECK ((payment_channel = ANY (ARRAY['qris'::text, 'transfer'::text, 'credit'::text])));

CREATE VIEW "api"."admin_profiles" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path,
    trust_score,
    status,
    suspended_until,
    created_at
   FROM market.profiles
  WHERE ( SELECT ops.has_admin() AS has_admin);

CREATE VIEW "api"."campaigns" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    slug,
    title,
    type,
    category_id,
    status,
    platforms,
    brief,
    required_hashtags,
    required_mentions,
    required_links,
    sponsored_label,
    min_duration_sec,
    max_duration_sec,
    dos,
    donts,
    example_urls,
    faq,
    service_mode,
    start_at,
    submit_deadline,
    view_window_days,
    review_mode,
    min_followers,
    min_account_age_days,
    min_trust_score,
    kyc_required,
    min_views,
    max_clips_per_clipper,
    clipper_quota,
    allow_video_reuse,
    visibility,
    is_template,
    pinned_until,
    pinned_rank,
    fee_rule_id,
    created_at
   FROM market.campaigns;

CREATE VIEW "api"."organizations" WITH (security_invoker=true) AS  SELECT id,
    name,
    org_type,
    legal_name,
    npwp,
    address,
    is_agency,
    fee_rule_id,
    status,
    verified_at,
    created_at
   FROM market.organizations;

CREATE POLICY "invoices_finance_read" ON "finance"."invoices"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text, 'admin_ops'::text]) AS has_admin));

REVOKE ALL ON FUNCTION "api"."manage_user"(uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."manage_user"(uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."manage_user"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."manage_user"(uuid, text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."mark_fulfillment_delivered"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."mark_fulfillment_delivered"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."mark_fulfillment_delivered"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."mark_fulfillment_delivered"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."org_credit"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."org_credit"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."org_credit"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."org_credit"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."pay_invoice_with_credit"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."pay_invoice_with_credit"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."pay_invoice_with_credit"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."pay_invoice_with_credit"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."org_credit_available"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."org_credit_available"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."org_credit_available"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."settle_invoice"(finance.invoices, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."settle_invoice"(finance.invoices, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."settle_invoice"(finance.invoices, uuid) TO "postgres";

GRANT SELECT ON TABLE "api"."admin_profiles" TO "authenticated";

GRANT SELECT ON TABLE "api"."campaigns" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."organizations" TO "authenticated";

-- Data: kunci config yang perlu dibaca app pindah ke public.* (RLS settings_public_read).
update ops.settings set key = 'public.' || key
 where key in ('finance.hold_days', 'finance.refund_transfer_fee_idr', 'market.brand_review_auto_approve_hours')
   and not exists (select 1 from ops.settings s where s.key = 'public.' || ops.settings.key);
