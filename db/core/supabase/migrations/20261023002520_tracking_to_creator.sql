SET local check_function_bodies = off;

-- 4DB-4b: akun sosmed + token, isi submisi, dan snapshot pindah ke project creator. Migration ini tidak memindahkan data lama;
-- DB admin yang sudah berisi data tracking harus dipindah dulu (token Vault ikut, id snapshot lama bentrok dengan id creator).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM tracking.social_accounts) OR EXISTS (SELECT 1 FROM tracking.submissions)
     OR EXISTS (SELECT 1 FROM tracking.view_snapshots) THEN
    RAISE EXCEPTION 'admin sudah berisi data tracking: pindahkan akun sosmed, token, submisi, snapshot ke project creator dulu (4DB-4b)';
  END IF;
END $$;

SELECT cron.unschedule('token-refresh');

SELECT cron.unschedule('track-due');

SELECT cron.unschedule('track-worker');

SELECT pgmq.drop_queue('tracking');

REVOKE ALL ON SEQUENCE "tracking"."view_snapshots_id_seq" FROM "postgres";

REVOKE ALL ("created_at") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("external_id") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("followers") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("handle") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("id") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("platform_created_at") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("platform") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("status") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("user_id") ON TABLE "tracking"."social_accounts" FROM "authenticated";

REVOKE ALL ("verified_at") ON TABLE "tracking"."social_accounts" FROM "authenticated";

DROP TRIGGER "campaigns_replicate" ON "market"."campaigns";

DROP TRIGGER "social_accounts_limit" ON "tracking"."social_accounts";

DROP FUNCTION "api"."store_social_token"(uuid, text);

DROP FUNCTION "api"."worker_account_status"(uuid, text);

DROP FUNCTION "api"."worker_account_token"(uuid);

DROP FUNCTION "api"."worker_accounts_to_refresh"(interval);

DROP FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer, bigint);

DROP FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone);

DROP FUNCTION "api"."worker_post_gone"(uuid, text);

DROP FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb);

DROP FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid);

DROP FUNCTION "api"."worker_submission_context"(uuid);

DROP FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text);

DROP FUNCTION "tracking"."check_account_limit"();

DROP FUNCTION "tracking"."enqueue_due_submissions"(integer);

DROP FUNCTION "tracking"."lagging_count"();

DROP FUNCTION "tracking"."paused_count"(uuid);

ALTER TABLE "tracking"."social_accounts"
  ALTER COLUMN "id" DROP DEFAULT;

ALTER TABLE "tracking"."submissions"
  ALTER COLUMN "id" DROP DEFAULT;

ALTER TABLE "tracking"."social_accounts"
  DROP COLUMN "token_ref";

ALTER TABLE "tracking"."submissions"
  DROP COLUMN "retry_after";

ALTER TABLE "tracking"."view_snapshots"
  ALTER COLUMN "id" DROP IDENTITY;

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "review_route" text NOT NULL DEFAULT 'manual'::text;

CREATE OR REPLACE FUNCTION api.bridge_close_account (
  p_user uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles;
begin
  select * into pr from market.profiles p where p.id = p_user for update;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'no_profile');
  end if;
  if pr.status = 'closed' then
    return jsonb_build_object('ok', true, 'reason', 'already_closed');
  end if;
  if exists (select 1 from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
             where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state in ('pending', 'available')
             group by a.id, e.state having sum(e.amount) <> 0) then
    return jsonb_build_object('ok', false, 'reason', 'balance_remaining');
  end if;
  if exists (select 1 from finance.payouts p where p.user_id = p_user and p.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'payout_in_progress');
  end if;
  if exists (select 1 from finance.fulfillments f where f.user_id = p_user and f.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'fulfillment_in_progress');
  end if;

  update tracking.submissions set status = 'forfeited', next_poll_at = null where user_id = p_user and status in ('tracking', 'flagged');
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  update market.profiles set referral_code = null, suspended_until = null, status = 'closed' where id = p_user;
  -- isi profil, token & akun sosmed milik creator (anonimkan, hapus token, putus akun)
  perform bus.emit('creator', 'profile.anonymize', jsonb_build_object('user_id', p_user));
  return jsonb_build_object('ok', true, 'reason', null);
end $function$;

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
  perform bus.emit('creator', 'social.reset', jsonb_build_object('account_id', a.id));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'social.reset', 'social_account:' || a.id, jsonb_build_object('status', a.status, 'user_id', a.user_id),
          jsonb_build_object('status', 'revoked', 'note', left(btrim(p_note), 500)));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_ack (
  p_queue  text,
  p_msg_id bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_queue is null or p_queue not in ('email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.delete(p_queue, p_msg_id);
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
  if p_queue is null or p_queue not in ('email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message, q.read_ct
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.submission_post_gone (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  perform tracking.post_gone((p ->> 'submission_id')::uuid, p ->> 'reason');
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'high', jsonb_build_object('submission_id', p ->> 'submission_id', 'step', 'post_gone',
                                                                               'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_submissions_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.decide_new_submission((p_row ->> 'id')::uuid);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'high', jsonb_build_object('submission_id', p_row ->> 'id', 'step', 'decide',
                                                                               'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_view_snapshots_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.apply_snapshot((p_row ->> 'id')::bigint);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'high', jsonb_build_object('snapshot_id', p_row ->> 'id', 'step', 'snapshot',
                                                                               'error', sqlerrm));
end $function$;

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
begin
  select * into v from tracking.view_snapshots x where x.id = p_snapshot;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
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
  update tracking.submissions set last_snapshot_at = taken, last_views = p_views, next_poll_at = nxt where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', raised or st = 'flagged', 'next_poll_at', nxt, 'locked', st = 'locked');
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
  update tracking.submissions set status = 'in_review' where id = s.id;
  if s.review_route = 'auto' then
    perform trust.apply_submission_decision(s.id, 'auto_approve', null, null, null, 'auto');
  end if;
  update market.claims set status = 'submitted' where id = s.claim_id and status = 'open';
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

CREATE OR REPLACE FUNCTION tracking.lagging_count()
  RETURNS integer
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select count(*)::int from tracking.submissions s join tracking.social_accounts a on a.id = s.social_account_id and a.status = 'verified'
   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours';
$function$;

CREATE OR REPLACE FUNCTION tracking.post_gone (
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
  lost jsonb;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return;
  end if;
  lost := finance.pending_amounts(s.id);  -- nominal hangus untuk notifikasi, dibaca sebelum reverse_earning
  fid := trust.raise_flag('submission', s.id, 'FR-06', 100, jsonb_build_object('post_gone', true, 'reason', p_reason), 'actioned');
  -- §12 Trust Score turun dari fraud flag; FR-06 langsung ditindak tanpa antrean, jadi penaltinya di sini (setara reverse).
  insert into trust.score_events (user_id, delta, reason, ref_id)
  values (s.user_id, coalesce((ops.cfg('trust.score_deltas') ->> 'post_gone')::int, -10), 'fraud_flag', fid::text);
  update tracking.submissions set status = 'forfeited', next_poll_at = null where id = s.id;
  perform finance.reverse_earning(s.id, 'post_gone');
  perform ops.enqueue_notification(s.user_id, 'submission.forfeited', market.campaign_ref(s.campaign_id)
                                   || jsonb_build_object('submission_id', s.id, 'reason', coalesce(p_reason, 'post_gone'),
                                                         'platform', s.platform, 'views', greatest(s.counted_views, coalesce(s.last_views, 0)),
                                                         'amounts', lost));
end $function$;

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_review_route_check" CHECK ((review_route = ANY (ARRAY['auto'::text, 'manual'::text])));

CREATE TRIGGER campaigns_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:status,start_at,submit_deadline,view_window_days,pinned_until', 'creator:status,submit_deadline,view_window_days');

CREATE TRIGGER claims_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.claims
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('creator:campaign_id,user_id,status,expires_at,created_at');

CREATE TRIGGER settings_replicate
  AFTER INSERT OR DELETE OR UPDATE ON ops.settings
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('creator:value,updated_by,updated_at');

CREATE TRIGGER submissions_replicate
  AFTER INSERT OR DELETE OR UPDATE ON tracking.submissions
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('creator:status,counted_views,locked_at,next_poll_at');

REVOKE ALL ON FUNCTION "bus_in"."submission_post_gone"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."submission_post_gone"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."submission_post_gone"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."tracking_submissions_applied"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."tracking_submissions_applied"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."tracking_submissions_applied"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."tracking_view_snapshots_applied"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."tracking_view_snapshots_applied"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."tracking_view_snapshots_applied"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."apply_snapshot"(bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."apply_snapshot"(bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."apply_snapshot"(bigint) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."decide_new_submission"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."decide_new_submission"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."decide_new_submission"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."lagging_count"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."lagging_count"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."lagging_count"() TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."post_gone"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."post_gone"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."post_gone"(uuid, text) TO "postgres";

REVOKE ALL ON TABLE "tracking"."social_accounts" FROM "authenticated";

GRANT SELECT ON TABLE "tracking"."social_accounts" TO "authenticated";
