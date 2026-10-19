-- job:lifecycle (5 menit) — transisi S-01 berdasarkan waktu + lock submisi (S-03) + settlement mode + auto-approve review brand.
--   scheduled → live (start_at) · live/paused → tracking (submit_deadline) · tracking/exhausted → settling (tidak ada submisi
--   aktif & settlement pool selesai) · settling → settled (semua submisi settled/berakhir; notifikasi campaign.settled).
-- Lock di akhir view window (posted_at + view_window_days, atau campaign exhausted/settling = campaign selesai):
--   snapshot final sudah ada → accrue (idempoten, termasuk koreksi turun) lalu locked; belum ada → next_poll_at = now() supaya
--   track-due mengantrekan poll final (worker_submission_context.final = true, worker_record_snapshot mengunci); poll final tidak
--   kunjung datang (token mati, API error) → setelah tracking.final_grace_hours dikunci dengan views terakhir + alert.
-- Juga: payout instant macet dikirim ulang ke bridge disburse (finance.retry_instant_payouts).
-- locked → settled (release earning) dikerjakan job earning-release (finance.release_earnings) karena harus satu transaksi
-- dengan jurnal pending → Tersedia.
-- Identitas campaign untuk payload notifikasi (template email identity): {campaign_id, campaign_title, org_id}.
create function market.campaign_ref(p_campaign uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'org_id', c.org_id)
                     from market.campaigns c where c.id = p_campaign), '{}');
end $$;

create function market.run_lifecycle() returns void
language plpgsql security definer set search_path = '' as $$
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
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();

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

  -- Kesehatan job tracking (F-A01): submisi terlambat > 2 jam dari jadwal poll → alert (maks satu per 6 jam).
  select count(*) into n from tracking.submissions s
   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours';
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $$;

revoke execute on function market.campaign_ref(uuid), market.run_lifecycle() from public;
