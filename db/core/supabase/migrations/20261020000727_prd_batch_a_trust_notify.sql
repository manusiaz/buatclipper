SET local check_function_bodies = off;

DROP VIEW "api"."notifications";

DROP FUNCTION "api"."worker_dequeue"(text, integer, integer);

ALTER TABLE "ops"."notifications"
  ADD COLUMN "in_app" boolean NOT NULL DEFAULT true;

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
  elsif p_action = 'ban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'banned' where id = pr.id;
    update market.claims set status = 'released' where user_id = pr.id and status = 'open';
  elsif p_action = 'unban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id and status in ('banned', 'suspended');
  else
    perform market.fail('invalid:action', p_action);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'user.' || p_action, 'profile:' || pr.id,
          jsonb_build_object('status', pr.status, 'trust_score', pr.trust_score, 'suspended_until', pr.suspended_until),
          prm || jsonb_build_object('status', (select p.status from market.profiles p where p.id = pr.id),
                                    'trust_score', (select p.trust_score from market.profiles p where p.id = pr.id)));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_create_submission (
  p_user         uuid,
  p_claim        uuid,
  p_account      uuid,
  p_post_id      text,
  p_url          text,
  p_posted_at    timestamp with time zone,
  p_caption      text,
  p_duration_sec integer
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
    insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at)
    values (cl.id, p_user, c.id, a.id, a.platform, p_post_id, p_url, p_posted_at) returning id into sid;
  exception when unique_violation then
    raise exception 'already_submitted' using errcode = 'P0001';
  end;
  st := case when c.review_mode in ('manual', 'brand')
                  or (p_duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))
             then 'in_review' else 'tracking' end;
  update tracking.submissions set status = 'in_review' where id = sid;
  if st = 'tracking' then  -- review auto: keputusan tercatat seperti review biasa (Trust Score naik, notifikasi submission.approved)
    perform trust.apply_submission_decision(sid, 'auto_approve', null, null, null, 'auto');
  end if;
  update market.claims set status = 'submitted' where id = cl.id;
  if c.review_mode = 'brand' and st = 'in_review' then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'submission.pending_review',
                              market.campaign_ref(c.id) || jsonb_build_object('submission_id', sid));
  end if;
  return jsonb_build_object('submission_id', sid, 'status', st);
end $function$;

CREATE OR REPLACE FUNCTION api.worker_dequeue (
  p_queue      text,
  p_qty        integer DEFAULT 20,
  p_vt_seconds integer DEFAULT 300
)
  RETURNS TABLE (
    msg_id  bigint,
    message jsonb,
    read_ct integer
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message, q.read_ct
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
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
      or coalesce(a.followers, 0) < (ops.cfg('trust.fraud.low_followers', '100'))::int)
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
  update tracking.submissions set last_snapshot_at = taken, next_poll_at = nxt where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', raised or st = 'flagged', 'next_poll_at', nxt, 'locked', st = 'locked');
end $function$;

CREATE OR REPLACE FUNCTION api.worker_retry_later (
  p_queue   text,
  p_msg_id  bigint,
  p_seconds integer
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, least(greatest(coalesce(p_seconds, 300), 1), 21600));
end $function$;

CREATE OR REPLACE FUNCTION finance.accrue_referral_bonus()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pct numeric := (ops.cfg('finance.referral_bonus_pct', '5'))::numeric;
  idr uuid := finance.idr();
  rev uuid;
  x record;
  bonus numeric;
begin
  if pct <= 0 then
    return;
  end if;
  rev := finance.account('platform_revenue', null, idr);
  for x in select le.id as entry_id, le.amount, r.referrer_id
             from market.referrals r
             join market.profiles rf on rf.id = r.referrer_id and rf.status = 'active'
             join finance.ledger_accounts a on a.owner_type = 'user_wallet' and a.owner_id = r.referred_id and a.reward_type_id = idr
             join finance.ledger_entries le on le.account_id = a.id and le.state = 'available' and le.ref_type = 'release'
            where r.qualified_at is not null and r.bonus_until is not null and le.amount > 0
              -- C5.3: teman satu NIK/rekening/perangkat dengan pengundang → bonus batal (flag FR-04/FR-05 belum di-dismiss)
              and not exists (select 1 from trust.fraud_flags f
                               where f.target_type = 'profile' and f.signal in ('FR-04', 'FR-05') and f.status <> 'dismissed'
                                 and ((f.target_id = r.referred_id and f.details -> 'related_user_ids' ? r.referrer_id::text)
                                   or (f.target_id = r.referrer_id and f.details -> 'related_user_ids' ? r.referred_id::text)))
              and le.created_at >= r.qualified_at and le.created_at < r.bonus_until
              and not exists (select 1 from finance.ledger_entries b where b.ref_type = 'referral_bonus' and b.ref_id = le.id::text)
            order by le.id loop
    bonus := trunc(x.amount * pct / 100);
    continue when bonus <= 0;
    perform finance.post(gen_random_uuid(), jsonb_build_array(
      finance.e(rev, -bonus, 'referral_bonus', x.entry_id::text),
      finance.e(finance.account('user_wallet', x.referrer_id, idr), bonus, 'referral_bonus', x.entry_id::text, 'available')));
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION ops.enqueue_notification (
  p_user    uuid,
  p_event   text,
  p_payload jsonb   DEFAULT '{}'::jsonb,
  p_email   boolean DEFAULT true
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  nid bigint;
  promo boolean := p_event in ('campaign.new', 'broadcast.sent');
  ch jsonb := case when jsonb_typeof(p_payload -> 'channels') = 'array' then p_payload -> 'channels' end;
  want_email boolean;
  want_push boolean;
begin
  insert into ops.notifications (user_id, event, payload, in_app)
  values (p_user, p_event, p_payload, ch is null or ch ? 'in_app') returning id into nid;
  want_email := p_email and (ch is null or ch ? 'email')
                and (not promo or coalesce((select np.email_promotions from ops.notification_prefs np where np.user_id = p_user), true));
  want_push := p_email and (ch is null or ch ? 'push');
  if want_email or want_push then
    perform pgmq.send('email', jsonb_build_object('notification_id', nid, 'user_id', p_user, 'event', p_event,
                                                  'promo', promo, 'email', want_email, 'push', want_push));
  end if;
  return nid;
end $function$;

CREATE OR REPLACE FUNCTION trust.recalc_scores()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
  d_clean int := coalesce(((select st.value from ops.settings st where st.key = 'trust.score_deltas') ->> 'clean_tenure')::int, 1);
begin
  if d_clean <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id)
    select pr.id, greatest(least(d_clean, 100), -100), 'clean_tenure', x.period::text
      from market.profiles pr
      cross join lateral (select floor(extract(epoch from now() - pr.created_at) / (30 * 86400))::int as period) x
     where pr.status = 'active' and x.period >= 1
       and not exists (select 1 from trust.score_events e where e.user_id = pr.id and e.reason = 'clean_tenure' and e.ref_id = x.period::text)
       and not exists (select 1 from trust.score_events e where e.user_id = pr.id and e.delta < 0
                        and e.created_at > now() - interval '30 days')
       and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held', 'actioned')
                        and f.created_at > now() - interval '30 days'
                        and ((f.target_type = 'profile' and f.target_id = pr.id)
                          or (f.target_type = 'submission' and f.target_id in (select s.id from tracking.submissions s where s.user_id = pr.id))));
  end if;
  update market.profiles p set trust_score = x.score
    from (select pr.id, least(100, greatest(0, 50 + coalesce(sum(e.delta), 0)))::smallint as score
            from market.profiles pr left join trust.score_events e on e.user_id = pr.id
           group by pr.id) x
   where x.id = p.id and p.trust_score <> x.score;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE VIEW "api"."notifications" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    event,
    payload,
    read_at,
    created_at
   FROM ops.notifications
  WHERE in_app;

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer) TO "service_role";

GRANT UPDATE ("read_at") ON TABLE "api"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "api"."notifications" TO "authenticated";
