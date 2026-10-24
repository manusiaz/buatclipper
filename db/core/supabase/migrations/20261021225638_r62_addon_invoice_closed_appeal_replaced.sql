SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.appeal_submission (
  p_submission uuid,
  p_message    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  s tracking.submissions;
  pr market.profiles;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null or s.user_id <> uid then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.status is distinct from 'active' then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_message, ''))) not between 1 and 1000 then
    perform market.fail('invalid:message', 'alasan banding 1–1000 karakter');
  end if;
  if s.status <> 'rejected' then
    perform market.fail('invalid_state:' || s.status, 'banding hanya untuk submisi yang ditolak');
  end if;
  -- Campaign selesai (dana sisa bisa di-refund/rollover) → banding ditutup; banding yang berjalan menahan settle.
  if exists (select 1 from market.campaigns c where c.id = s.campaign_id and c.status in ('settling', 'settled', 'cancelled')) then
    perform market.fail('appeal_closed', 'campaign sudah selesai, banding ditutup');
  end if;
  -- Clip pengganti sudah memenuhi max_clips_per_clipper → banding clip lama tidak boleh menambah clip berbayar
  -- (banding yang berjalan sendiri ikut terhitung di claim_check, jadi pengganti tak bisa dikirim selama banding).
  if (select count(*) from tracking.submissions t where t.campaign_id = s.campaign_id and t.user_id = uid and t.id <> s.id
        and t.status not in ('rejected', 'rejected_final'))
     >= (select c.max_clips_per_clipper from market.campaigns c where c.id = s.campaign_id) then
    perform market.fail('appeal_replaced', 'clip pengganti sudah dikirim, banding tidak tersedia');
  end if;
  begin
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, message)
    values ('submission', s.id, uid, 'appeal', btrim(p_message));
  exception when unique_violation then
    perform market.fail('appeal_used', 'banding hanya sekali per submisi');
  end;
  update tracking.submissions set status = 'appealed' where id = s.id;
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

CREATE OR REPLACE FUNCTION finance.void_stale_addons()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  update finance.invoices i set status = 'void'
   where i.status = 'issued' and i.kind in ('topup', 'pinned')
     and exists (select 1 from market.campaigns c where c.id = i.campaign_id
                  and c.status in ('tracking', 'exhausted', 'settling', 'settled', 'cancelled', 'rejected'));
$function$;

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
    elsif r.window_end + grace <= now() then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at > now() + interval '1 hour' then
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
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;

REVOKE ALL ON FUNCTION "finance"."void_stale_addons"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."void_stale_addons"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."void_stale_addons"() TO "postgres";
