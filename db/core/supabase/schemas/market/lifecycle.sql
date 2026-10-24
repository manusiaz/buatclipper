-- job:lifecycle (5 menit) — transisi S-01 berdasarkan waktu + lock submisi (S-03) + settlement mode + auto-approve review brand.
--   scheduled → live (start_at) · live/paused → tracking (submit_deadline) · tracking/exhausted → settling (tidak ada submisi
--   aktif & settlement pool selesai) · settling → settled (semua submisi settled/berakhir; notifikasi campaign.settled).
-- Lock di akhir view window (posted_at + view_window_days, atau campaign exhausted/settling = campaign selesai):
--   snapshot final sudah ada → accrue (idempoten, termasuk koreksi turun) lalu locked; belum ada → next_poll_at = now() supaya
--   track-due mengantrekan poll final (worker_submission_context.final = true, worker_record_snapshot mengunci); poll final tidak
--   kunjung datang (token mati, API error) → setelah tracking.final_grace_hours dikunci dengan views terakhir + alert.
-- Campaign baru live → campaign.new ke clipper eligible (market.announce_campaign). Juga: payout instant macet dikirim ulang ke bridge disburse (finance.retry_instant_payouts).
-- locked → settled (release earning) dikerjakan job earning-release (finance.release_earnings) karena harus satu transaksi
-- dengan jurnal pending → Tersedia.
-- Identitas campaign untuk payload notifikasi (template email identity): {campaign_id, campaign_title, org_id}.
create function market.campaign_ref(p_campaign uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'org_id', c.org_id)
                     from market.campaigns c where c.id = p_campaign), '{}');
end $$;

-- campaign.new (promosi, F-X01; email ikut E-34 lewat enqueue_notification) ke clipper yang eligible saat campaign live:
-- profil active, bukan anggota org pemilik, punya akun sosmed verified di platform campaign dengan follower & umur akun cukup,
-- Trust Score ≥ ambang; visibility invite → hanya yang diundang. Satu set query per campaign; dipanggil tepat sekali dari
-- transisi scheduled → live (S-01 tidak bisa kembali ke scheduled), jadi idempoten per campaign.
create function market.announce_campaign(p_campaign uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  select count(ops.enqueue_notification(p.id, 'campaign.new', x.payload)) into n
    from market.campaigns c
    cross join lateral (select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                  'org_name', (select o.name from market.organizations o where o.id = c.org_id),
                                                  'platforms', to_jsonb(c.platforms),
                                                  'rate_per_1k', market.rate_per_1k(c.id)) as payload) x
    join market.profiles p on p.status = 'active' and p.trust_score >= c.min_trust_score
   where c.id = p_campaign and not c.is_template
     and not exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = p.id)
     and (c.visibility <> 'invite' or exists (select 1 from market.campaign_invites i where i.campaign_id = c.id and i.user_id = p.id))
     -- Sekali per clipper per campaign: diumumkan ulang (F-B08) hanya menjangkau yang baru eligible.
     and not exists (select 1 from ops.notifications n where n.user_id = p.id and n.event = 'campaign.new'
                      and n.payload ->> 'campaign_id' = c.id::text)
     and exists (select 1 from tracking.social_accounts a
                 where a.user_id = p.id and a.status = 'verified' and a.platform = any (c.platforms)
                   and coalesce(a.followers, 0) >= c.min_followers
                   and (c.min_account_age_days = 0
                        or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days)));
  return n;
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
  -- Suspend berdurasi yang sudah lewat → active lagi (sanksi tetap tercatat dengan until); entry point yang mensyaratkan
  -- status 'active' (submit, sosmed, org, notifikasi) tidak terkunci selamanya menunggu unsuspend manual (R75).
  update market.profiles set status = 'active', suspended_until = null where status = 'suspended' and suspended_until <= now();
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
    -- Snapshot final yang belum diproses apply_snapshot (hook replika gagal → alert, CX11): proses ulang lewat apply_snapshot
    -- (cek fraud + accrual + lock), bukan accrual langsung; masih gagal → tetap tracking (dicoba lagi run berikutnya) + alert.
    -- Penanda = applied_snapshot_id milik admin (last_snapshot_at replika creator tiba walau hook gagal, CL15/CX12); naik
    -- berurutan, jadi ≥ final = final sudah diproses (snapshot sesudah final bisa tiba saat replika status tertinggal, CX15).
    if fin is not null and not exists (select 1 from tracking.submissions t where t.id = r.id and t.applied_snapshot_id >= fin) then
      begin
        perform tracking.apply_snapshot(fin);
      exception when others then
        perform ops.raise_alert('tracking.apply_failed', 'critical',
                                jsonb_build_object('snapshot_id', fin, 'step', 'lifecycle', 'error', sqlerrm), interval '1 hour');
      end;
    -- Sudah diproses (mis. flagged saat snapshot final tiba, lalu flag diselesaikan) → accrual final + lock.
    elsif fin is not null then
      perform finance.accrue_earnings(r.id, fin);
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
    -- Grace dihitung dari yang terakhir: akhir window atau masuk tracking (approve/overturn telat) → poll final sempat jalan (R69).
    -- Lock tanpa snapshot final hanya bila antrean creator → admin sudah melewati batas itu (ping creator yang dikirim sesudahnya
    -- sudah tiba, FIFO): bus macet bukan berarti snapshot final tidak ada — earning tidak dikunci dari data yang tertinggal.
    elsif greatest(r.window_end, coalesce((select max(d.created_at) from trust.review_decisions d
                                            where d.target_type = 'submission' and d.target_id = r.id
                                              and d.decision in ('approve', 'auto_approve', 'overturn')), r.window_end)) + grace
          < least(now(), coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity')) then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at is null or r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
  end loop;

  -- Submisi dibuat di project creator dan tiba lewat bus (FIFO). Campaign yang tutup karena deadline baru settle setelah ping
  -- creator yang dikirim > 1 menit sesudah deadline tiba: semua submisi yang diterima creator sebelum deadline sudah di sini (R83-1).
  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and (c.status <> 'tracking'
          or coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity') > c.submit_deadline + interval '1 minute')
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
end $$;

revoke execute on function market.campaign_ref(uuid), market.announce_campaign(uuid), market.run_lifecycle() from public;
