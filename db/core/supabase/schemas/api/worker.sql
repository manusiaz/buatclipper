-- RPC service_role untuk Edge Function core (notify, fulfill) + penerapan replika tracking dari creator (snapshot, submisi baru,
-- post hilang). Edge Function tracking (social, track-worker, refresh-tokens) ada di project creator. Edge Function memakai
-- secret key core (policy:fn-cron-key), jadi fungsi ini tidak membaca JWT; aman karena EXECUTE hanya untuk service_role.
-- Error: errcode P0001 + kode stabil di message (worker memetakan kode), P0002 not_found:<objek>.

-- ---------- queue (Supabase Queues) ----------
create function api.worker_dequeue(p_queue text, p_qty int default 20, p_vt_seconds int default 300)
returns table (msg_id bigint, message jsonb, read_ct int)
language plpgsql security definer set search_path = '' as $$
begin
  if p_queue is null or p_queue not in ('email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message, q.read_ct
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
end $$;

create function api.worker_ack(p_queue text, p_msg_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_queue is null or p_queue not in ('email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.delete(p_queue, p_msg_id);
end $$;

-- ---------- tracking ----------
-- Poll final: view window lewat (posted_at + view_window_days) atau campaign selesai (exhausted/settling/settled), dan snapshot
-- final belum ada.
create function tracking.final_due(p_submission uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return exists (select 1 from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
                 where s.id = p_submission
                   and (s.posted_at + make_interval(days => c.view_window_days) <= now()
                        or c.status in ('exhausted', 'settling', 'settled')))
     and not exists (select 1 from tracking.view_snapshots v where v.submission_id = p_submission and v.is_final);
end $$;

-- Snapshot dari creator tiba (replika, hook bus_in.tracking_view_snapshots_applied). Urutan: sinyal fraud (FR-06 caption,
-- FR-01 engagement, FR-02 lonjakan vs median akun, FR-03 akun baru, FR-09 durasi tonton/skip rate, FR-10 views/reach, FR-11
-- negara/sumber penonton, FR-08 turun saat lock; FR-09/11 hanya kalau ambangnya ada di config) → accrue_earnings → lock kalau
-- final → jadwal poll berikutnya (tracking.poll_schedule per umur posting, tidak melewati akhir view window supaya poll final
-- tepat waktu; next_poll_at direplika ke creator). avg_watch_time Instagram dalam milidetik, platform lain detik.
create function tracking.apply_snapshot(p_snapshot bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Post dihapus/diprivate sebelum lock (§11, FR-06; event submission.post_gone dari creator/track-worker): earning pending hangus
-- + notifikasi. Setelah lock tidak berpengaruh.
create function tracking.post_gone(p_submission uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Submisi baru dari creator (replika, status validating; validasi claim/akun/video di creator api.worker_create_submission):
-- review_route auto → tracking (keputusan tercatat seperti review biasa: Trust Score, notifikasi submission.approved), manual →
-- in_review; claim → submitted; FR-07 (§12) cover hampir identik dengan submisi akun sosmed lain dalam 90 hari = konten duplikat
-- lintas akun → flag (review manual; earning tertahan selama flag terbuka; jarak Hamming dHash ≤ trust.fraud.cover_distance,
-- default 6: re-encode ≤ 5, cover lain ≥ 28); campaign review brand → notifikasi brand.
create function tracking.decide_new_submission(p_submission uuid) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Hook replika (tidak pernah raise: batch bus macet). Gagal → alert untuk ops, baris replika tetap tersimpan.
create function bus_in.tracking_submissions_applied(p_op text, p_row jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  if p_op = 'upsert' then
    perform tracking.decide_new_submission((p_row ->> 'id')::uuid);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', p_row ->> 'id', 'step', 'decide',
                                                                               'error', sqlerrm));
end $$;

create function bus_in.tracking_view_snapshots_applied(p_op text, p_row jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  if p_op = 'upsert' then
    perform tracking.apply_snapshot((p_row ->> 'id')::bigint);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('snapshot_id', p_row ->> 'id', 'step', 'snapshot',
                                                                               'error', sqlerrm));
end $$;

create function bus_in.submission_post_gone(p jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  perform tracking.post_gone((p ->> 'submission_id')::uuid, p ->> 'reason');
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', p ->> 'submission_id', 'step', 'post_gone',
                                                                               'error', sqlerrm));
end $$;

-- ---------- notifikasi (worker notify, alur 4) ----------
create function api.worker_notification(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n ops.notifications;
begin
  select * into n from ops.notifications x where x.id = p_id;
  if not found then
    return null;
  end if;
  return jsonb_build_object('user_id', n.user_id, 'event', n.event, 'payload', n.payload,
                            'promo', n.event in ('campaign.new', 'broadcast.sent'));
end $$;

-- One-click unsubscribe email promosi (List-Unsubscribe-Post); email transaksional tetap jalan.
create function api.worker_unsubscribe(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into ops.notification_prefs (user_id, email_promotions) values (p_user, false)
  on conflict (user_id) do update set email_promotions = false, updated_at = now();
end $$;

-- ---------- fulfillment non-tunai (worker fulfill, F-B03, S-06) ----------
-- Status tetap requested selama percobaan ulang (S-06 tidak punya processing → on_hold); processing → delivered hanya saat sukses.
-- next_retry_at = lease 5 menit supaya worker paralel tidak mengirim dua kali.
create function api.worker_fulfillments_due(p_limit int)
returns table (id uuid, user_id uuid, reward_type_id uuid, amount numeric, recipient jsonb, fulfillment text, webhook_url text,
               webhook_secret text, attempts smallint)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  return query
  with due as (
    select f.id as fid from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
     where (f.status = 'requested'
            -- pool kode sempat kosong: lanjut otomatis begitu ada kode bebas lagi (S-06 on_hold → processing)
            -- (atau kodenya sudah terpasang tapi hasil kirim belum tercatat: worker mati di tengah jalan)
            or (f.status = 'on_hold' and f.last_error = 'code_pool_empty' and rt.fulfillment = 'code_pool'
                and exists (select 1 from finance.reward_codes rc where rc.reward_type_id = f.reward_type_id
                             and (rc.fulfillment_id is null or rc.fulfillment_id = f.id)))
            -- webhook macet yang dikirim ulang admin (api.retry_fulfillment: next_retry_at terisi lagi)
            or (f.status = 'on_hold' and rt.fulfillment = 'webhook' and f.next_retry_at is not null))
       and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
       and not finance.withdraw_blocked(f.user_id)  -- flag profil setelah klaim → tidak dikirim sampai direview (R71)
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    -- Lease lama masih terisi = worker sebelumnya mati sebelum mencatat hasil: kiriman itu mungkin sudah sampai ke brand.
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes', leased_until = now() + interval '5 minutes',
           delivery_uncertain = f.delivery_uncertain or f.leased_until is not null
      from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $$;

-- Pasang satu kode dari pool (idempoten: kode yang sudah terpasang dikembalikan lagi). Pool kosong → on_hold + alert, NULL.
create function api.worker_assign_code(p_fulfillment uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  f finance.fulfillments;
  cid uuid;
  code text;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'code_pool' then
    raise exception 'invalid:fulfillment_kind' using errcode = 'P0001';
  end if;
  select rc.code into code from finance.reward_codes rc where rc.fulfillment_id = f.id;
  if code is not null then
    return code;
  end if;
  if f.status <> 'requested' and not (f.status = 'on_hold' and f.last_error = 'code_pool_empty') then
    return null;
  end if;
  select rc.id, rc.code into cid, code from finance.reward_codes rc
   where rc.reward_type_id = f.reward_type_id and rc.fulfillment_id is null
   order by rc.created_at, rc.id limit 1 for update skip locked;
  if cid is null then
    update finance.fulfillments set status = 'on_hold', last_error = 'code_pool_empty', leased_until = null where id = f.id;
    perform ops.raise_alert('fulfillment.stuck', 'warning',
                            jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id, 'reason', 'code_pool_empty'));
    return null;
  end if;
  update finance.reward_codes set fulfillment_id = f.id, assigned_at = now() where id = cid;
  return code;
end $$;

-- Hasil kirim: sukses → delivered + notifikasi; gagal → coba lagi 5 menit, setelah 12 percobaan → on_hold + alert.
create function api.worker_fulfillment_result(p_fulfillment uuid, p_ok boolean, p_ref text, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  f finance.fulfillments;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status = 'delivered' then
    return;
  end if;
  if p_ok then
    if f.status in ('requested', 'on_hold') then
      update finance.fulfillments set status = 'processing' where id = f.id;
    end if;
    update finance.fulfillments set status = 'delivered', delivered_ref = p_ref, delivered_at = now(), last_error = null,
           next_retry_at = null, leased_until = null
     where id = f.id;
    perform ops.enqueue_notification(f.user_id, 'fulfillment.delivered', finance.amount_ref(f.reward_type_id, f.amount)
                                     || jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id,
                                                           'reward_name', (select rt.name from market.reward_types rt where rt.id = f.reward_type_id)));
  else
    -- 4xx = brand menolak dengan jelas; selain itu (timeout, network_error, 5xx) reward mungkin sudah diproses brand.
    update finance.fulfillments set attempts = attempts + 1, last_error = left(p_error, 500), next_retry_at = now() + interval '5 minutes',
           leased_until = null, delivery_uncertain = delivery_uncertain or coalesce(p_error, '') !~ '^http_4[0-9][0-9]$'
     where id = f.id;
    if f.attempts + 1 >= 12 and f.status in ('requested', 'on_hold') then
      update finance.fulfillments set status = 'on_hold', next_retry_at = null where id = f.id;
      perform ops.raise_alert('fulfillment.stuck', 'warning',
                              jsonb_build_object('fulfillment_id', f.id, 'attempts', f.attempts + 1, 'error', left(p_error, 500)));
    end if;
  end if;
end $$;

revoke execute on function api.worker_dequeue(text, int, int), api.worker_ack(text, bigint),
  tracking.final_due(uuid), tracking.apply_snapshot(bigint), tracking.post_gone(uuid, text), tracking.decide_new_submission(uuid),
  bus_in.tracking_submissions_applied(text, jsonb), bus_in.tracking_view_snapshots_applied(text, jsonb), bus_in.submission_post_gone(jsonb),
  api.worker_notification(bigint), api.worker_unsubscribe(uuid), api.worker_fulfillments_due(int), api.worker_assign_code(uuid),
  api.worker_fulfillment_result(uuid, boolean, text, text)
  from public, anon, authenticated;
grant execute on function api.worker_dequeue(text, int, int), api.worker_ack(text, bigint),
  api.worker_notification(bigint), api.worker_unsubscribe(uuid), api.worker_fulfillments_due(int), api.worker_assign_code(uuid),
  api.worker_fulfillment_result(uuid, boolean, text, text)
  to service_role;
