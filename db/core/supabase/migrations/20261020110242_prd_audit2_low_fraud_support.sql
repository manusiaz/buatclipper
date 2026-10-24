SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bridge_fraud_device_params()
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select jsonb_build_object('window_hours', (ops.cfg('trust.fraud.shared_device_window_hours', '24'))::int,
                            'min_accounts', (ops.cfg('trust.fraud.shared_device_min_accounts', '3'))::int);
$function$;

CREATE OR REPLACE FUNCTION api.reset_social_account (
  p_account uuid,
  p_note    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
begin
  if not ops.has_admin('admin_support', 'admin_moderator') then
    perform market.fail('auth:forbidden', 'butuh admin_support/admin_moderator aal2', '42501');
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    perform market.fail('invalid:reason', 'aksi admin atas user wajib alasan');
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    perform market.fail('not_found:social_account', null, 'P0002');
  end if;
  if a.status = 'disconnected' then
    perform market.fail('invalid_state:' || a.status);
  end if;
  delete from vault.secrets v where v.id = a.token_ref;
  update tracking.social_accounts set status = 'revoked', token_ref = null where id = a.id;
  update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                   jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'social.reset', 'social_account:' || a.id, jsonb_build_object('status', a.status, 'user_id', a.user_id),
          jsonb_build_object('status', 'revoked', 'note', left(btrim(p_note), 500)));
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_fraud_flag (
  p_flag   uuid,
  p_action text,
  p_note   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  f trust.fraud_flags;
  target_user uuid;
  sub tracking.submissions;
  x record;
  score_delta smallint;
  notify boolean;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('warn', 'hold', 'reverse', 'suspend', 'ban', 'dismiss') then
    raise exception 'invalid:action' using errcode = 'P0001';
  end if;
  select * into f from trust.fraud_flags ff where ff.id = p_flag for update;
  if not found then
    raise exception 'not_found:fraud_flag' using errcode = 'P0002';
  end if;
  if f.status not in ('open', 'held') then
    raise exception 'invalid_state:%', f.status using errcode = 'P0001';
  end if;
  target_user := case f.target_type
    when 'profile' then f.target_id
    when 'submission' then (select s.user_id from tracking.submissions s where s.id = f.target_id)
    when 'social_account' then (select a.user_id from tracking.social_accounts a where a.id = f.target_id)
    when 'payout' then (select p.user_id from finance.payouts p where p.id = f.target_id) end;
  if f.target_type = 'submission' then
    select * into sub from tracking.submissions s where s.id = f.target_id for update;
  end if;
  if p_action = 'reverse' and f.target_type not in ('submission', 'profile') then
    raise exception 'invalid:action_for_target' using errcode = 'P0001';
  end if;

  if p_action = 'hold' then
    update trust.fraud_flags set status = 'held' where id = f.id;
    if sub.status = 'tracking' then
      update tracking.submissions set status = 'flagged' where id = sub.id;
    end if;
    -- A4.2 "Clipper menerima notifikasi" untuk setiap tindakan, termasuk tahan.
    perform ops.enqueue_notification(target_user, 'earning.held',
                                     case when sub.id is null then '{}'::jsonb else market.campaign_ref(sub.campaign_id)
                                          || jsonb_build_object('submission_id', sub.id) end
                                     || jsonb_build_object('target_type', f.target_type, 'signal', f.signal));
    if f.target_type = 'payout' then
      -- Instant requested sudah diteruskan ke penyedia (alur 11); menahannya membuka refund saat transfer berjalan.
      update finance.payouts set status = 'on_hold', hold_reason = 'fraud:' || f.signal
       where id = f.target_id and status = 'requested' and channel = 'batch';
    end if;
  elsif p_action = 'dismiss' then
    update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = f.id;
    if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                               and o.target_id = sub.id and o.status in ('open', 'held')) then
      update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
    end if;
  else
    update trust.fraud_flags set status = 'actioned', resolved_by = uid, resolved_at = now() where id = f.id;
    if p_action = 'reverse' then
      for x in select s.id, s.status from tracking.submissions s
                where (f.target_type = 'submission' and s.id = f.target_id)
                   or (f.target_type = 'profile' and s.user_id = f.target_id and s.status in ('tracking', 'flagged', 'locked'))
                order by s.id loop
        -- submisi locked yang masih punya earning belum rilis juga kehilangan earning → clipper tetap dikabari
        notify := x.status <> 'locked' or exists (select 1 from finance.clip_earnings ce where ce.submission_id = x.id
                                                   and ce.released_at is null and ce.amount > 0);
        perform finance.reverse_earning(x.id, 'fraud:' || f.signal);
        if x.status in ('tracking', 'flagged') then
          update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
        end if;
        if notify then
          perform ops.enqueue_notification(target_user, 'submission.forfeited',
                                           market.campaign_ref((select s.campaign_id from tracking.submissions s where s.id = x.id))
                                           || jsonb_build_object('submission_id', x.id, 'reason', 'fraud:' || f.signal));
        end if;
      end loop;
    elsif p_action = 'suspend' then
      update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days'
       where id = target_user and status in ('active', 'suspended');
      perform finance.hold_payouts(target_user, null, 'profile_suspended');
      perform ops.enqueue_notification(target_user, 'account.suspended',
                                       jsonb_build_object('until', now() + interval '30 days', 'signal', f.signal));
    elsif p_action = 'ban' then
      update market.profiles set status = 'banned' where id = target_user and status <> 'closed';
      perform trust.apply_ban(target_user, f.signal, jsonb_build_object('signal', f.signal, 'flag_id', f.id));
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', target_user));
    elsif p_action = 'warn' then
      perform ops.enqueue_notification(target_user, 'account.warned', jsonb_build_object('signal', f.signal));
      -- peringatan = earning tetap jalan: submisi yang ditahan flag ini lanjut tracking bila tak ada flag lain (R30-5)
      if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                                 and o.target_id = sub.id and o.status in ('open', 'held')) then
        update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
      end if;
    end if;
  end if;
  -- §12: setiap sanksi tercatat dan bisa dibanding sekali (trust.sanctions); ban fraud queue juga memblokir login identity
  if p_action <> 'dismiss' and target_user is not null then
    perform trust.record_sanction(target_user, p_action, f.id, p_note,
                                  case when p_action = 'suspend' then now() + interval '30 days' end, p_action = 'ban');
  end if;

  score_delta := case p_action when 'warn' then -5 when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_create_submission (
  p_user         uuid,
  p_claim        uuid,
  p_account      uuid,
  p_post_id      text,
  p_url          text,
  p_posted_at    timestamp with time zone,
  p_caption      text,
  p_duration_sec integer,
  p_cover_hash   bigint                   DEFAULT NULL::bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cl market.claims;
  c market.campaigns;
  a tracking.social_accounts;
  missing text[];
  sid uuid;
  st tracking.submission_status;
  dup record;
begin
  if not exists (select 1 from market.profiles pr where pr.id = p_user and pr.status = 'active') then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into cl from market.claims k where k.id = p_claim for update;
  if not found then
    raise exception 'claim_not_open' using errcode = 'P0001';
  end if;
  if cl.user_id <> p_user then
    raise exception 'not_your_claim' using errcode = 'P0001';
  end if;
  if cl.status <> 'open' or cl.expires_at <= now() then
    raise exception 'claim_not_open' using errcode = 'P0001';
  end if;
  select * into c from market.campaigns k where k.id = cl.campaign_id;
  if c.status <> 'live' or c.submit_deadline <= now() then
    raise exception 'campaign_closed' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account;
  if not found or a.user_id <> p_user then
    raise exception 'account_not_yours' using errcode = 'P0001';
  end if;
  if a.status <> 'verified' then
    raise exception 'account_inactive' using errcode = 'P0001';
  end if;
  if not (a.platform = any (c.platforms)) then
    raise exception 'platform_not_allowed' using errcode = 'P0001';
  end if;
  if p_posted_at is null or p_posted_at < cl.created_at then
    raise exception 'posted_before_claim' using errcode = 'P0001';
  end if;
  missing := api.missing_brief_tags(c.id, p_caption);
  if cardinality(missing) > 0 then
    raise exception 'missing_tags:%', array_to_string(missing, ',') using errcode = 'P0001';
  end if;
  if p_duration_sec < c.min_duration_sec or p_duration_sec > c.max_duration_sec then
    raise exception 'duration_out_of_range' using errcode = 'P0001';
  end if;
  if exists (select 1 from tracking.submissions t where t.campaign_id = c.id and t.platform = a.platform and t.post_id = p_post_id) then
    raise exception 'already_submitted' using errcode = 'P0001';
  end if;
  if not c.allow_video_reuse and exists (select 1 from tracking.submissions t
                                         where t.platform = a.platform and t.post_id = p_post_id and t.campaign_id <> c.id) then
    raise exception 'reused_video' using errcode = 'P0001';
  end if;
  if p_post_id is null or btrim(p_post_id) = '' or p_url is null or p_url !~ '^https://' then
    raise exception 'invalid:url' using errcode = 'P0001';
  end if;

  begin
    insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at, cover_hash)
    values (cl.id, p_user, c.id, a.id, a.platform, p_post_id, p_url, p_posted_at, p_cover_hash) returning id into sid;
  exception when unique_violation then
    raise exception 'already_submitted' using errcode = 'P0001';
  end;
  -- §11: API TikTok tidak memberi info sound → campaign musik/sound di TikTok selalu diverifikasi manual di moderasi.
  st := case when c.review_mode in ('manual', 'brand')
                  or (p_duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))
                  or (c.type = 'music' and a.platform = 'tiktok')
             then 'in_review' else 'tracking' end;
  update tracking.submissions set status = 'in_review' where id = sid;
  if st = 'tracking' then  -- review auto: keputusan tercatat seperti review biasa (Trust Score naik, notifikasi submission.approved)
    perform trust.apply_submission_decision(sid, 'auto_approve', null, null, null, 'auto');
  end if;
  update market.claims set status = 'submitted' where id = cl.id;
  -- FR-07 (§12): cover hampir identik dengan submisi akun sosmed lain dalam 90 hari = konten duplikat lintas akun → flag (review
  -- manual; earning tertahan selama flag terbuka). Jarak Hamming dHash ≤ trust.fraud.cover_distance (default 6: re-encode ≤ 5,
  -- cover lain ≥ 28).
  if p_cover_hash is not null then
    select array_agg(t.id order by t.created_at) ids, array_agg(distinct t.user_id) users into dup
      from (select t.id, t.user_id, t.created_at from tracking.submissions t
             where t.cover_hash is not null and t.created_at > now() - interval '90 days' and t.social_account_id <> a.id
               and bit_count((t.cover_hash # p_cover_hash)::bit(64)) <= (ops.cfg('trust.fraud.cover_distance', '6'))::int
             order by t.created_at limit 20) t;
    if dup.ids is not null then
      perform trust.raise_flag('submission', sid, 'FR-07', 60,
                               jsonb_build_object('duplicates', to_jsonb(dup.ids),
                                                  'related_user_ids', to_jsonb(array_remove(dup.users, p_user))));
    end if;
  end if;
  if c.review_mode = 'brand' and st = 'in_review' then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'submission.pending_review',
                              market.campaign_ref(c.id) || jsonb_build_object('submission_id', sid));
  end if;
  return jsonb_build_object('submission_id', sid, 'status', st);
end $function$;

CREATE OR REPLACE FUNCTION api.worker_post_gone (
  p_submission uuid,
  p_reason     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  fid uuid;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return;
  end if;
  fid := trust.raise_flag('submission', s.id, 'FR-06', 100, jsonb_build_object('post_gone', true, 'reason', p_reason), 'actioned');
  -- §12 Trust Score turun dari fraud flag; FR-06 langsung ditindak tanpa antrean, jadi penaltinya di sini (setara reverse).
  insert into trust.score_events (user_id, delta, reason, ref_id)
  values (s.user_id, coalesce((ops.cfg('trust.score_deltas') ->> 'post_gone')::int, -10), 'fraud_flag', fid::text);
  update tracking.submissions set status = 'forfeited', next_poll_at = null where id = s.id;
  perform finance.reverse_earning(s.id, 'post_gone');
  perform ops.enqueue_notification(s.user_id, 'submission.forfeited', market.campaign_ref(s.campaign_id)
                                   || jsonb_build_object('submission_id', s.id, 'reason', coalesce(p_reason, 'post_gone')));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_record_snapshot (
  p_submission uuid,
  p_views      bigint,
  p_likes      bigint,
  p_comments   bigint,
  p_shares     bigint,
  p_caption    text,
  p_raw        jsonb,
  p_extra      jsonb  DEFAULT '{}'::jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
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
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return jsonb_build_object('snapshot_id', null, 'flagged', s.status = 'flagged', 'next_poll_at', null,
                              'locked', s.status in ('locked', 'settled'));
  end if;
  if p_views is null or p_views < 0 then
    raise exception 'invalid:views' using errcode = 'P0001';
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select * into a from tracking.social_accounts x where x.id = s.social_account_id;
  window_end := s.posted_at + make_interval(days => c.view_window_days);
  fin := tracking.final_due(s.id);
  insert into tracking.view_snapshots (submission_id, taken_at, views, likes, comments, shares, is_final, raw)
  values (s.id, clock_timestamp(), p_views, p_likes, p_comments, p_shares, fin,
          nullif(case when jsonb_typeof(p_raw) = 'object' then p_raw when p_raw is null then '{}' else jsonb_build_object('response', p_raw) end
                 || case when jsonb_typeof(p_extra) = 'object' and p_extra <> '{}' then jsonb_build_object('extra', p_extra) else '{}' end,
                 '{}'))
  returning id, taken_at into sid, taken;

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
  update tracking.submissions set last_snapshot_at = taken, last_views = p_views, next_poll_at = nxt where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', raised or st = 'flagged', 'next_poll_at', nxt, 'locked', st = 'locked');
end $function$;

REVOKE ALL ON FUNCTION "api"."bridge_fraud_device_params"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_fraud_device_params"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fraud_device_params"() TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fraud_device_params"() TO "service_role";

REVOKE ALL ON FUNCTION "api"."reset_social_account"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."reset_social_account"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."reset_social_account"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."reset_social_account"(uuid, text) TO "postgres";
