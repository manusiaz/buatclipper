SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION tracking.apply_snapshot (
  p_snapshot bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  v tracking.view_snapshots;
  s tracking.submissions;
  p_views bigint;
  p_likes bigint;
  p_comments bigint;
  p_shares bigint;
  p_caption text;
  p_extra jsonb;
  c market.campaigns;
  a tracking.social_accounts;
  fin boolean;
  sid bigint;
  taken timestamptz;
  hold boolean := false;
  raised boolean := false;
  missing text[];
  med numeric;
  peers int;
  reach numeric;
  watch numeric;
  skip numeric;
  id_views numeric;
  all_views numeric;
  off_views numeric;
  src_views numeric;
  window_end timestamptz;
  every_h numeric;
  nxt timestamptz;
  st tracking.submission_status;
  prev bigint;
begin
  select * into v from tracking.view_snapshots x where x.id = p_snapshot;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  -- Snapshot sebelumnya yang belum diproses (hook replika gagal → alert) diproses dulu, berurutan: jatah settlement (snapshot
  -- pertama setelah cut-off, R76) dan cek fraud tidak terlewat oleh snapshot berikutnya (CL16/CX13). Masih gagal → snapshot ini
  -- ikut gagal (alert), tidak ada yang diproses melompati. applied_snapshot_id naik berurutan, jadi id ≤ itu = sudah diproses.
  for prev in select x.id from tracking.view_snapshots x
               where x.submission_id = v.submission_id and x.id < v.id
                 and x.id > coalesce((select t.applied_snapshot_id from tracking.submissions t where t.id = v.submission_id), 0)
               order by x.id loop
    perform tracking.apply_snapshot(prev);
  end loop;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    -- submisi tidak dilacak lagi (locked/forfeited/…; creator bisa masih polling selama replika status tertinggal): snapshot
    -- tidak berefek tapi tetap ditandai diproses — tanpa ini replay berurutan di atas berulang eksponensial (CL18)
    update tracking.submissions set applied_snapshot_id = greatest(coalesce(applied_snapshot_id, 0), v.id) where id = s.id;
    return jsonb_build_object('snapshot_id', v.id, 'flagged', s.status = 'flagged', 'next_poll_at', null,
                              'locked', s.status in ('locked', 'settled'));
  end if;
  p_views := v.views; p_likes := v.likes; p_comments := v.comments; p_shares := v.shares;
  p_caption := v.raw ->> 'caption';
  p_extra := case when jsonb_typeof(v.raw -> 'extra') = 'object' then v.raw -> 'extra' else '{}' end;
  sid := v.id;
  taken := v.taken_at;
  fin := v.is_final;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select * into a from tracking.social_accounts x where x.id = s.social_account_id;
  window_end := s.posted_at + make_interval(days => c.view_window_days);

  if p_caption is not null then
    missing := api.missing_brief_tags(c.id, p_caption);
    if cardinality(missing) > 0 then
      raised := trust.raise_flag('submission', s.id, 'FR-06', 80, jsonb_build_object('missing', missing, 'snapshot_id', sid))
                is not null or raised;
      hold := true;
    end if;
  end if;
  if p_likes is not null and p_views >= greatest(c.min_views, 1000)
     and (p_likes + coalesce(p_comments, 0) + coalesce(p_shares, 0))::numeric / p_views
         < (ops.cfg('trust.fraud.like_rate_min', '0.005'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-01', 50,
                               jsonb_build_object('views', p_views, 'likes', p_likes, 'comments', p_comments, 'shares', p_shares,
                                                  'snapshot_id', sid)) is not null or raised;
  end if;
  select percentile_cont(0.5) within group (order by o.counted_views), count(*) into med, peers
    from tracking.submissions o
   where o.social_account_id = s.social_account_id and o.id <> s.id and o.status in ('tracking', 'flagged', 'locked', 'settled');
  if peers >= 3 and med > 0 and p_views > med * (ops.cfg('trust.fraud.spike_multiplier', '10'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-02', 70, jsonb_build_object('views', p_views, 'median', med, 'peers', peers))
              is not null or raised;
    hold := true;
  end if;
  if (a.platform_created_at > now() - make_interval(days => (ops.cfg('trust.fraud.new_account_days', '14'))::int)
      or a.followers < (ops.cfg('trust.fraud.low_followers', '100'))::int)  -- follower tak diketahui (null) bukan "sedikit"
     and p_views >= (ops.cfg('trust.fraud.new_account_views', '100000'))::bigint then
    raised := trust.raise_flag('submission', s.id, 'FR-03', 60,
                               jsonb_build_object('views', p_views, 'account_created_at', a.platform_created_at,
                                                  'followers', a.followers)) is not null or raised;
  end if;
  reach := case when jsonb_typeof(p_extra -> 'reach') = 'number' then (p_extra ->> 'reach')::numeric end;
  if reach > 0 and p_views / reach > (ops.cfg('trust.fraud.views_over_reach', '3'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-10', 60, jsonb_build_object('views', p_views, 'reach', reach))
              is not null or raised;
  end if;
  watch := case when jsonb_typeof(p_extra -> 'avg_watch_time') = 'number'
                then (p_extra ->> 'avg_watch_time')::numeric / case when s.platform = 'instagram' then 1000 else 1 end end;
  skip := case when jsonb_typeof(p_extra -> 'skip_rate') = 'number' then (p_extra ->> 'skip_rate')::numeric end;
  if p_views >= greatest(c.min_views, 1000)
     and (watch < (ops.cfg('trust.fraud.min_avg_watch_sec'))::numeric or skip > (ops.cfg('trust.fraud.max_skip_rate'))::numeric) then
    raised := trust.raise_flag('submission', s.id, 'FR-09', 50, jsonb_build_object('avg_watch_sec', watch, 'skip_rate', skip, 'snapshot_id', sid))
              is not null or raised;
  end if;
  if jsonb_typeof(p_extra -> 'countries') = 'object' then
    select coalesce(sum(x.value::numeric) filter (where upper(x.key) = 'ID'), 0), sum(x.value::numeric) into id_views, all_views
      from jsonb_each_text(p_extra -> 'countries') x where x.value ~ '^[0-9]+(\.[0-9]+)?$';
    if all_views > 0 and p_views >= greatest(c.min_views, 1000)
       and id_views / all_views < (ops.cfg('trust.fraud.min_id_country_share'))::numeric then
      raised := trust.raise_flag('submission', s.id, 'FR-11', 60,
                                 jsonb_build_object('id_share', round(id_views / all_views, 4), 'countries', p_extra -> 'countries',
                                                    'traffic_sources', p_extra -> 'traffic_sources', 'snapshot_id', sid)) is not null or raised;
      hold := true;  -- FR-11: tahan earning
    end if;
  end if;
  -- FR-11 sumber traffic: porsi views dari sumber trust.fraud.offsite_traffic_sources (iklan/promosi berbayar, embed autoplay)
  -- di atas trust.fraud.max_offsite_traffic_share = views dibeli → tahan earning sampai moderator memutus.
  if jsonb_typeof(p_extra -> 'traffic_sources') = 'object' then
    select coalesce(sum(x.value::numeric) filter (where upper(x.key) in (select jsonb_array_elements_text(
             ops.cfg('trust.fraud.offsite_traffic_sources', '["ADVERTISING","PROMOTED","NO_LINK_EMBEDDED"]')))), 0),
           sum(x.value::numeric) into off_views, src_views
      from jsonb_each_text(p_extra -> 'traffic_sources') x where x.value ~ '^[0-9]+(\.[0-9]+)?$';
    if src_views > 0 and p_views >= greatest(c.min_views, 1000)
       and off_views / src_views > (ops.cfg('trust.fraud.max_offsite_traffic_share', '0.5'))::numeric then
      raised := trust.raise_flag('submission', s.id, 'FR-11', 60,
                                 jsonb_build_object('offsite_share', round(off_views / src_views, 4),
                                                    'traffic_sources', p_extra -> 'traffic_sources', 'snapshot_id', sid)) is not null or raised;
      hold := true;
    end if;
  end if;
  if fin and p_views < s.counted_views
     and (s.counted_views - p_views) * 100 >= s.counted_views * (ops.cfg('trust.fraud.lock_drop_pct', '20'))::numeric then
    -- FR-08: koreksi otomatis (accrue_earnings → correct_down); flag hanya catatan, tidak menahan release.
    perform trust.raise_flag('submission', s.id, 'FR-08', 40,
                             jsonb_build_object('counted_views', s.counted_views, 'final_views', p_views), 'actioned');
  end if;
  if hold and s.status = 'tracking' then
    update tracking.submissions set status = 'flagged' where id = s.id;
  end if;

  perform finance.accrue_earnings(s.id, sid);

  select t.status into st from tracking.submissions t where t.id = s.id;
  if fin and st = 'tracking' then
    update tracking.submissions set status = 'locked', locked_at = now() where id = s.id;
    st := 'locked';
  end if;
  if not fin and now() < window_end then
    select (e.value ->> 'every_hours')::numeric into every_h
      from jsonb_array_elements(ops.cfg('tracking.poll_schedule',
             '[{"until_hours":72,"every_hours":4},{"until_hours":336,"every_hours":24},{"until_hours":null,"every_hours":72}]'))
           with ordinality e(value, i)
     where e.value ->> 'until_hours' is null
        or (e.value ->> 'until_hours')::numeric > extract(epoch from now() - s.posted_at) / 3600
     order by e.i limit 1;
    nxt := least(now() + coalesce(every_h, 24) * interval '1 hour', window_end);
  end if;
  update tracking.submissions set applied_snapshot_id = sid, next_poll_at = nxt where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', raised or st = 'flagged', 'next_poll_at', nxt, 'locked', st = 'locked');
end $function$;
