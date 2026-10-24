SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus.resync (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cols text[];
  pk text[] := bus.pk_columns(p_table);
  r jsonb;
  n int := 0;
begin
  select string_to_array(split_part(a, ':', 2), ',') into cols
    from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target;
  if cols is null then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  -- Tulisan baru menunggu sampai resync commit: event resync (snapshot lama) tidak bisa menyalip event tulisan yang lebih baru (R83-2).
  execute format('lock table %s in share mode', p_table);
  for r in execute format('select to_jsonb(t) from %s t', p_table) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert',
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
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
end $function$;

CREATE OR REPLACE FUNCTION tracking.decide_new_submission (
  p_submission uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  c market.campaigns;
  dup record;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found or s.status <> 'validating' then
    return;
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  update market.claims set status = 'submitted' where id = s.claim_id and status = 'open';
  -- Creator menerima submisi dari replika status campaign yang bisa tertinggal (mis. dibatalkan / sudah settle saat bus telat):
  -- campaign yang tidak lagi menerima klip → ditolak tanpa penalti Trust Score (bukan kesalahan clipper) + kabar.
  if c.status not in ('live', 'paused', 'tracking', 'exhausted') then
    update tracking.submissions set status = 'rejected' where id = s.id;  -- banding ditolak appeal_closed (campaign selesai)
    perform ops.enqueue_notification(s.user_id, 'submission.rejected', market.campaign_ref(c.id)
                                     || jsonb_build_object('submission_id', s.id, 'url', s.url, 'platform', s.platform, 'final', true,
                                                           'reason', 'Campaign sudah tidak menerima klip saat submisi kamu tercatat.'));
    return;
  end if;
  update tracking.submissions set status = 'in_review' where id = s.id;
  if s.review_route = 'auto' then
    perform trust.apply_submission_decision(s.id, 'auto_approve', null, null, null, 'auto');
  end if;
  if s.cover_hash is not null then
    select array_agg(t.id order by t.created_at) ids, array_agg(distinct t.user_id) users into dup
      from (select t.id, t.user_id, t.created_at from tracking.submissions t
             where t.cover_hash is not null and t.created_at > now() - interval '90 days' and t.social_account_id <> s.social_account_id
               and t.id <> s.id
               and bit_count((t.cover_hash # s.cover_hash)::bit(64)) <= (ops.cfg('trust.fraud.cover_distance', '6'))::int
             order by t.created_at limit 20) t;
    if dup.ids is not null then
      perform trust.raise_flag('submission', s.id, 'FR-07', 60,
                               jsonb_build_object('duplicates', to_jsonb(dup.ids),
                                                  'related_user_ids', to_jsonb(array_remove(dup.users, s.user_id))));
    end if;
  end if;
  if c.review_mode = 'brand' and s.review_route = 'manual' then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'submission.pending_review',
                              market.campaign_ref(c.id) || jsonb_build_object('submission_id', s.id));
  end if;
end $function$;
