SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bridge_attach_fulfillment_export (
  p_reward_type uuid,
  p_file_ref    text,
  p_exported    uuid[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.fulfillments f where f.id = any (coalesce(p_exported, '{}')) order by f.id for update;
  -- Profil penerima dikunci (FOR SHARE) supaya ban/suspend yang sedang berjalan selesai dulu sebelum cek withdraw_blocked.
  perform 1 from market.profiles pr where pr.id in (select f.user_id from finance.fulfillments f where f.id = any (coalesce(p_exported, '{}')))
   order by pr.id for share;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
                                 where f.id = e.id and f.reward_type_id = p_reward_type and rt.fulfillment = 'manual_export'
                                   and (f.status = 'requested' or f.export_ref = p_file_ref)
                                   and (f.export_ref = p_file_ref or not finance.withdraw_blocked(f.user_id)))) then  -- R73
    raise exception 'export_stale' using errcode = 'P0001', detail = 'klaim berubah sejak dibaca; ekspor ulang';
  end if;
  update finance.fulfillments set status = 'processing', export_ref = p_file_ref where id = any (p_exported) and status = 'requested';
end $function$;

CREATE OR REPLACE FUNCTION finance.issue_invoice (
  p_org         uuid,
  p_campaign    uuid,
  p_kind        text,
  p_subtotal    numeric,
  p_service_fee numeric                  DEFAULT 0,
  p_pin_until   timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_pool_topups jsonb                    DEFAULT NULL::jsonb
)
  RETURNS finance.invoices
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
    if exists (select 1 from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
                 left join lateral (select sum((e ->> 'amount')::numeric) as amount from jsonb_array_elements(p_pool_topups) e
                                     where (e ->> 'pool_id')::uuid = pl.id) t on true
                where pl.campaign_id = p_campaign and rt.stock is not null
                  and (p_kind = 'campaign' or t.amount is not null)
                group by rt.id, rt.stock having sum(coalesce(t.amount, pl.total)) > rt.stock) then
      perform market.fail('reward_stock_insufficient', 'stok reward tidak cukup untuk pool ini');
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
end $function$;

CREATE OR REPLACE FUNCTION finance.refund_cancelled_campaign (
  p_campaign uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
    from finance.invoices i where i.campaign_id = c.id and i.status = 'paid' and i.kind in ('campaign', 'topup', 'pinned', 'managed_service');
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
      update market.reward_types set stock = stock + x.bal where id = x.rt and stock is not null;
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
end $function$;

CREATE OR REPLACE FUNCTION finance.return_noncash_leftover (
  p_campaign uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  x record;
  entries jsonb := '[]';
begin
  for x in select rp.reward_type_id as rt, a.id as account, finance.balance(a.id) as bal
             from finance.reward_pools rp
             join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
            where rp.campaign_id = p_campaign and rp.reward_type_id <> finance.idr() and finance.balance(a.id) > 0
            order by rp.id for update of rp loop
    entries := entries || jsonb_build_array(finance.e(x.account, -x.bal, 'refund', 'leftover:' || p_campaign),
                                            finance.e(finance.account('bank_clearing', null, x.rt), x.bal, 'refund', 'leftover:' || p_campaign));
    update market.reward_types set stock = stock + x.bal where id = x.rt and stock is not null;
  end loop;
  if entries <> '[]' then
    perform finance.post(gen_random_uuid(), entries);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION finance.settle_invoice (
  inv finance.invoices
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
  days int;
begin
  -- Top-up / pin tak bermakna lagi bila campaign tidak bisa berjalan lagi (deadline lewat, habis, selesai, batal, ditolak) →
  -- tolak; invoice basi di-void lifecycle (finance.void_stale_addons).
  if inv.kind in ('topup', 'pinned') then
    perform 1 from market.campaigns c where c.id = inv.campaign_id
       and c.status in ('tracking', 'exhausted', 'settling', 'settled', 'cancelled', 'rejected') for share;
    if found then
      raise exception 'invoice_campaign_closed' using errcode = 'P0001';
    end if;
  end if;
  entries := jsonb_build_array(finance.e(finance.account('tax_payable', null, idr), inv.tax, 'invoice_payment', inv.id::text));
  if inv.total > inv.credit_applied then
    entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, idr), -(inv.total - inv.credit_applied),
                                                      'invoice_payment', inv.id::text));
  end if;
  if inv.credit_applied > 0 then
    entries := entries || jsonb_build_array(finance.e(finance.account('org_credit', inv.org_id, idr), -inv.credit_applied,
                                                      'invoice_payment', inv.id::text));
  end if;
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
        -- Stok terbatas (reward_types.stock = sisa yang belum dipakai pool mana pun) dikunci & dipotong di sini, lintas campaign (R73).
        if exists (select 1 from market.reward_types rt where rt.id = x.reward_type_id and rt.stock is not null) then
          update market.reward_types rt set stock = rt.stock - x.amount where rt.id = x.reward_type_id and rt.stock >= x.amount;
          if not found then
            raise exception 'reward_stock_insufficient' using errcode = 'P0001';
          end if;
        end if;
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

  -- Pin berlaku sejak lunas (atau sejak pin yang sedang berjalan habis), selama hari yang dibeli; campaign dikunci supaya
  -- dua invoice pin yang lunas bersamaan saling menyambung, tidak tumpang tindih.
  -- Invoice terbit sebelum pin_days ada: durasi = periode perkiraannya (pin_until − issued_at), dibatasi minggu yang dibayar
  -- (service_fee ÷ harga per minggu) karena periode itu ikut memuat sisa pin yang sedang berjalan saat terbit; maks 90 hari.
  if inv.kind = 'pinned' then
    days := coalesce(inv.pin_days, least(90, greatest(1,
      least(ceil(extract(epoch from inv.pin_until - inv.issued_at) / 86400),
            7 * round(inv.service_fee / nullif((select (s.value #>> '{}')::numeric from ops.settings s
                                                where s.key = 'public.billing.pin_price_per_week_idr'), 0))))));
    update market.campaigns set pinned_until = greatest(now(), coalesce(pinned_until, now())) + make_interval(days => days)
     where id = inv.campaign_id
    returning pinned_until into inv.pin_until;
    update finance.invoices set pin_until = inv.pin_until where id = inv.id;
  end if;
  perform market.notify_org(inv.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.paid',
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, inv.total)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $function$;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  n int;
begin
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();
  perform finance.void_stale_addons();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    if fin is not null then
      perform finance.accrue_earnings(r.id, fin);
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
    -- Grace dihitung dari yang terakhir: akhir window atau masuk tracking (approve/overturn telat) → poll final sempat jalan (R69).
    elsif greatest(r.window_end, coalesce((select max(d.created_at) from trust.review_decisions d
                                            where d.target_type = 'submission' and d.target_id = r.id
                                              and d.decision in ('approve', 'auto_approve', 'overturn')), r.window_end)) + grace <= now() then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at is null or r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
  end loop;

  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
    perform finance.return_noncash_leftover(r.id);
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;

REVOKE ALL ON FUNCTION "finance"."return_noncash_leftover"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."return_noncash_leftover"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."return_noncash_leftover"(uuid) TO "postgres";
