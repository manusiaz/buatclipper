-- RPC service_role untuk Edge Function core (track-worker, social, refresh-tokens, notify, fulfill). Edge Function memakai
-- secret key core (policy:fn-cron-key), jadi fungsi ini tidak membaca JWT; aman karena EXECUTE hanya untuk service_role.
-- Error: errcode P0001 + kode stabil di message (worker memetakan kode), P0002 not_found:<objek>.

-- ---------- queue (Supabase Queues) ----------
create function api.worker_dequeue(p_queue text, p_qty int default 20, p_vt_seconds int default 300)
returns table (msg_id bigint, message jsonb, read_ct int)
language plpgsql security definer set search_path = '' as $$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message, q.read_ct
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
end $$;

-- §11: API error / rate limit → coba lagi dengan backoff (bukan visibility timeout tetap). 1 detik–6 jam. p_submission:
-- penjadwal (enqueue_due_submissions) menahan pesan baru untuk submisi itu sampai pesan yang ditunda muncul lagi (+1 jam = lease
-- penjadwal, supaya pembacaan ulang yang tidak di-ack pun tetap tertutup),
-- termasuk poll final di ujung view window.
create function api.worker_retry_later(p_queue text, p_msg_id bigint, p_seconds int, p_submission uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  sec int := least(greatest(coalesce(p_seconds, 300), 1), 21600);
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, sec);
  if p_submission is not null then
    update tracking.submissions set retry_after = greatest(coalesce(retry_after, now()), now() + make_interval(secs => sec + 3600))
     where id = p_submission;
  end if;
end $$;

create function api.worker_ack(p_queue text, p_msg_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
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

create function api.worker_submission_context(p_submission uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  s tracking.submissions;
  a tracking.social_accounts;
  c market.campaigns;
  tok text;
begin
  select * into s from tracking.submissions t where t.id = p_submission;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  select * into a from tracking.social_accounts x where x.id = s.social_account_id;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select ds.decrypted_secret into tok from vault.decrypted_secrets ds where ds.id = a.token_ref;
  return jsonb_build_object(
    'submission', jsonb_build_object('id', s.id, 'platform', s.platform, 'post_id', s.post_id, 'url', s.url, 'posted_at', s.posted_at,
                                     'status', s.status, 'user_id', s.user_id, 'campaign_id', s.campaign_id,
                                     'counted_views', s.counted_views, 'last_snapshot_at', s.last_snapshot_at),
    'account', jsonb_build_object('id', a.id, 'external_id', a.external_id, 'handle', a.handle, 'status', a.status),
    'token', tok,
    'campaign', jsonb_build_object('required_hashtags', c.required_hashtags, 'required_mentions', c.required_mentions,
                                   'required_links', c.required_links, 'min_duration_sec', c.min_duration_sec,
                                   'max_duration_sec', c.max_duration_sec, 'view_window_days', c.view_window_days,
                                   'status', c.status),
    'final', tracking.final_due(s.id));
end $$;

-- Akun sosmed + token Vault (core/social: daftar video & submit atas nama akun itu).
create function api.worker_account_token(p_account uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a tracking.social_accounts;
begin
  select * into a from tracking.social_accounts x where x.id = p_account;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', a.id, 'user_id', a.user_id, 'platform', a.platform, 'external_id', a.external_id, 'handle', a.handle,
                            'status', a.status,
                            'token', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = a.token_ref));
end $$;

-- Poll dilewati (mis. X hanya dicek di 24 jam, 7 hari, dan lock): jadwal berikutnya = p_until, tidak melewati akhir view window.
create function api.worker_defer(p_submission uuid, p_until timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_until is null then
    raise exception 'invalid:until' using errcode = 'P0001';
  end if;
  update tracking.submissions t
     set next_poll_at = least(p_until, t.posted_at + make_interval(days => (select c.view_window_days from market.campaigns c
                                                                            where c.id = t.campaign_id)))
   where t.id = p_submission and t.status in ('tracking', 'flagged');
  if not found and not exists (select 1 from tracking.submissions t where t.id = p_submission) then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
end $$;

-- Satu snapshot dari worker (API sukses; error/rate limit tidak pernah dipanggil ke sini, §11). Urutan: simpan snapshot
-- (p_extra ikut di raw.extra) → sinyal fraud (FR-06 caption, FR-01 engagement, FR-02 lonjakan vs median akun, FR-03 akun baru,
-- FR-09 durasi tonton/skip rate, FR-10 views/reach, FR-11 negara penonton, FR-08 turun saat lock; FR-09/11 hanya kalau ambangnya
-- ada di config) → accrue_earnings → lock kalau final → jadwal poll berikutnya (tracking.poll_schedule per umur posting, tidak
-- melewati akhir view window supaya poll final tepat waktu). avg_watch_time Instagram dalam milidetik, platform lain detik.
create function api.worker_record_snapshot(p_submission uuid, p_views bigint, p_likes bigint, p_comments bigint, p_shares bigint,
                                           p_caption text, p_raw jsonb, p_extra jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Post dihapus/diprivate sebelum lock (§11, FR-06): earning pending hangus + notifikasi. Setelah lock tidak berpengaruh.
create function api.worker_post_gone(p_submission uuid, p_reason text) returns void
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

-- Status token akun sosmed: expired/revoked → tracking submisinya di-pause (next_poll_at NULL) + notifikasi sekali;
-- verified (reconnect) → polling lanjut, views kumulatif tetap terhitung selama dalam view window.
create function api.worker_account_status(p_account uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a tracking.social_accounts;
  new_status text := case p_status when 'expired' then 'token_expired' when 'revoked' then 'revoked' when 'verified' then 'verified' end;
begin
  if new_status is null then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  -- revoked lengket: hanya pulih lewat sambung ulang pemilik (worker_upsert_social_account), bukan hasil refresh/polling yang
  -- sedang jalan — termasuk 'expired' yang akan membuka jalan refresh menulis token lagi (R34-1, R35-1)
  if a.status in ('disconnected', 'revoked') then
    return;
  end if;
  if new_status = 'verified' then
    update tracking.social_accounts set status = 'verified', verified_at = now() where id = a.id;
    update tracking.submissions set next_poll_at = now()
     where social_account_id = a.id and status in ('tracking', 'flagged') and next_poll_at is null;
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                       jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle,
                                                          'paused_count', tracking.paused_count(a.id)));
    end if;
    update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  end if;
end $$;

-- Token yang kedaluwarsa dalam p_within (JSON Vault berisi expires_at). Token rusak/tanpa expires_at dilewati.
create function api.worker_accounts_to_refresh(p_within interval)
returns table (account_id uuid, platform market.platform, token text)
language plpgsql stable security definer set search_path = '' as $$
declare
  r record;
  exp timestamptz;
begin
  for r in select a.id, a.platform as pf, ds.decrypted_secret as tok
             from tracking.social_accounts a join vault.decrypted_secrets ds on ds.id = a.token_ref
            where a.status in ('verified', 'token_expired') order by a.id loop
    exp := null;
    if ltrim(r.tok) like '{%' then
      begin
        exp := (r.tok::jsonb ->> 'expires_at')::timestamptz;
      exception when others then
        exp := null;
      end;
    end if;
    if exp < now() + p_within then
      account_id := r.id;
      platform := r.pf;
      token := r.tok;
      return next;
    end if;
  end loop;
end $$;

-- Connect OAuth (F-C02): satu akun sosmed = satu clipper selamanya (social_taken); batas 3 akun/platform dari trigger.
-- Parameter text (bukan enum member/market): PostgREST meng-cast argumen RPC ke tipe deklarasi, dan role API tidak
-- punya USAGE ke schema internal → enum di parameter = 42501. Cast di dalam fungsi definer.
create function api.worker_upsert_social_account(p_user uuid, p_platform text, p_external_id text, p_handle text,
                                                 p_followers int, p_platform_created_at timestamptz, p_token text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  pf market.platform := p_platform::market.platform;
  a tracking.social_accounts;
  aid uuid;
begin
  if not exists (select 1 from market.profiles pr where pr.id = p_user and pr.status = 'active') then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.platform = pf and x.external_id = p_external_id for update;
  if found then
    if a.user_id <> p_user then
      raise exception 'social_taken' using errcode = 'P0001';
    end if;
    update tracking.social_accounts
       set handle = p_handle, followers = coalesce(p_followers, followers),
           platform_created_at = coalesce(p_platform_created_at, platform_created_at), status = 'verified', verified_at = now()
     where id = a.id;
    aid := a.id;
  else
    begin
      insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
      values (p_user, pf, p_external_id, p_handle, p_followers, p_platform_created_at) returning id into aid;
    exception when unique_violation then
      raise exception 'social_taken' using errcode = 'P0001';
    end;
  end if;
  if p_token is not null then
    perform api.store_social_token(aid, p_token);
  end if;
  update tracking.submissions set next_poll_at = now()
   where social_account_id = aid and status in ('tracking', 'flagged') and next_poll_at is null;
  return aid;
end $$;

-- Submit video (E-12, F-C06) setelah core/social memverifikasi kepemilikan lewat API platform. Kode error (P0001):
-- profile_inactive, claim_not_open, not_your_claim, campaign_closed, account_not_yours, account_inactive, platform_not_allowed,
-- posted_before_claim, missing_tags:<daftar>, duration_out_of_range, already_submitted, reused_video, invalid:url.
-- Status: validating → in_review (review manual/brand, atau campaign berbatas durasi tapi API tidak memberi durasi) atau
-- tracking (auto; langsung masuk jadwal poll). Claim → submitted.
create function api.worker_create_submission(p_user uuid, p_claim uuid, p_account uuid, p_post_id text, p_url text,
                                             p_posted_at timestamptz, p_caption text, p_duration_sec int,
                                             p_cover_hash bigint default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
  -- own_org dicek ulang: bergabung ke org pemilik (langsung / lewat agency) setelah claim tidak boleh lolos (R67).
  if exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = p_user)
     or exists (select 1 from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
                 where l.client_org_id = c.org_id and l.approved_at is not null and l.revoked_at is null and m.user_id = p_user) then
    raise exception 'not_eligible:own_org' using errcode = 'P0001';
  end if;
  -- Syarat akun dicek per akun yang dipakai submit, bukan cukup satu akun lolos saat claim (claim_check).
  if coalesce(a.followers, 0) < c.min_followers then
    raise exception 'not_eligible:min_followers' using errcode = 'P0001';
  end if;
  if c.min_account_age_days > 0 and (a.platform_created_at is null or a.platform_created_at > now() - make_interval(days => c.min_account_age_days)) then
    raise exception 'not_eligible:min_account_age' using errcode = 'P0001';
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
  -- Claim pengganti yang dibuka sebelum banding clip lama: kuota dicek ulang saat submit (serial dengan appeal_submission).
  perform pg_advisory_xact_lock(hashtextextended('clip_quota:' || c.id || ':' || p_user, 0));
  if (select count(*) from tracking.submissions t where t.campaign_id = c.id and t.user_id = p_user
        and t.status not in ('rejected', 'rejected_final')) >= c.max_clips_per_clipper then
    raise exception 'not_eligible:max_clips' using errcode = 'P0001';
  end if;
  -- Serial per video: dua submit bersamaan video yang sama (campaign berbeda) tidak sama-sama lolos cek pakai-ulang.
  perform pg_advisory_xact_lock(hashtextextended('submission_post:' || a.platform || ':' || coalesce(p_post_id, ''), 0));
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
    insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at, duration_sec, cover_hash)
    values (cl.id, p_user, c.id, a.id, a.platform, p_post_id, p_url, p_posted_at, p_duration_sec, p_cover_hash) returning id into sid;
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

revoke execute on function api.worker_dequeue(text, int, int), api.worker_ack(text, bigint), api.worker_retry_later(text, bigint, int, uuid),
  tracking.final_due(uuid),
  api.worker_account_token(uuid), api.worker_defer(uuid, timestamptz),
  api.worker_submission_context(uuid), api.worker_record_snapshot(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb),
  api.worker_post_gone(uuid, text), api.worker_account_status(uuid, text), api.worker_accounts_to_refresh(interval),
  api.worker_upsert_social_account(uuid, text, text, text, int, timestamptz, text),
  api.worker_create_submission(uuid, uuid, uuid, text, text, timestamptz, text, int, bigint), api.worker_notification(bigint),
  api.worker_unsubscribe(uuid), api.worker_fulfillments_due(int), api.worker_assign_code(uuid),
  api.worker_fulfillment_result(uuid, boolean, text, text)
  from public, anon, authenticated;
grant execute on function api.worker_dequeue(text, int, int), api.worker_ack(text, bigint), api.worker_retry_later(text, bigint, int, uuid),
  api.worker_account_token(uuid), api.worker_defer(uuid, timestamptz),
  api.worker_submission_context(uuid), api.worker_record_snapshot(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb),
  api.worker_post_gone(uuid, text), api.worker_account_status(uuid, text), api.worker_accounts_to_refresh(interval),
  api.worker_upsert_social_account(uuid, text, text, text, int, timestamptz, text),
  api.worker_create_submission(uuid, uuid, uuid, text, text, timestamptz, text, int, bigint), api.worker_notification(bigint),
  api.worker_unsubscribe(uuid), api.worker_fulfillments_due(int), api.worker_assign_code(uuid),
  api.worker_fulfillment_result(uuid, boolean, text, text)
  to service_role;
