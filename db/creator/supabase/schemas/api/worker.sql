-- RPC service_role untuk Edge Function creator (track-worker, social, refresh-tokens). Edge Function memakai secret key
-- creator (policy:fn-cron-key), jadi fungsi ini tidak membaca JWT; aman karena EXECUTE hanya untuk service_role.
-- Error: errcode P0001 + kode stabil di message (worker memetakan kode), P0002 not_found:<objek>.
-- Keputusan & uang di admin: snapshot direplika ke admin (fraud, accrual, lock, jadwal poll), submisi baru diputus admin
-- (review/auto, claim → submitted), post hilang = event submission.post_gone.

-- ---------- queue (Supabase Queues) ----------

create function api.worker_dequeue(p_queue text, p_qty int default 20, p_vt_seconds int default 300)
returns table (msg_id bigint, message jsonb, read_ct int)
language plpgsql security definer set search_path = '' as $$
begin
  if p_queue is null or p_queue not in ('tracking') then
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
  if p_queue is null or p_queue not in ('tracking') then
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
  if p_queue is null or p_queue not in ('tracking') then
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

-- Akun sosmed + token Vault (creator/social: daftar video & submit atas nama akun itu).
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

-- Poll dilewati (mis. X hanya dicek di 24 jam, 7 hari, dan lock): tidak diantre sebelum p_until, tidak melewati akhir view
-- window (lease_until; jadwal admin next_poll_at tetap).
create function api.worker_defer(p_submission uuid, p_until timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_until is null then
    raise exception 'invalid:until' using errcode = 'P0001';
  end if;
  update tracking.submissions t
     set lease_until = least(p_until, t.posted_at + make_interval(days => (select c.view_window_days from market.campaigns c
                                                                            where c.id = t.campaign_id)))
   where t.id = p_submission and t.status in ('tracking', 'flagged');
  if not found and not exists (select 1 from tracking.submissions t where t.id = p_submission) then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
end $$;

-- Satu snapshot dari worker (API sukses; error/rate limit tidak pernah dipanggil ke sini, §11). Snapshot (raw + caption + extra)
-- direplika ke admin: hook di sana menjalankan sinyal fraud FR-01/02/03/06/08/09/10/11, accrue_earnings, lock kalau final, dan
-- jadwal poll berikutnya (next_poll_at). Di sini: simpan snapshot + snapshot terakhir; lease antrean tetap sampai jadwal admin tiba.
create function api.worker_record_snapshot(p_submission uuid, p_views bigint, p_likes bigint, p_comments bigint, p_shares bigint,
                                           p_caption text, p_raw jsonb, p_extra jsonb default '{}')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s tracking.submissions;
  fin boolean;
  sid bigint;
  taken timestamptz;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return jsonb_build_object('snapshot_id', null, 'flagged', s.status = 'flagged', 'locked', s.status in ('locked', 'settled'));
  end if;
  if p_views is null or p_views < 0 then
    raise exception 'invalid:views' using errcode = 'P0001';
  end if;
  fin := tracking.final_due(s.id);
  insert into tracking.view_snapshots (submission_id, taken_at, views, likes, comments, shares, is_final, raw)
  values (s.id, clock_timestamp(), p_views, p_likes, p_comments, p_shares, fin,
          nullif(case when jsonb_typeof(p_raw) = 'object' then p_raw when p_raw is null then '{}' else jsonb_build_object('response', p_raw) end
                 || case when jsonb_typeof(p_extra) = 'object' and p_extra <> '{}' then jsonb_build_object('extra', p_extra) else '{}' end
                 || case when p_caption is not null then jsonb_build_object('caption', p_caption) else '{}' end,
                 '{}'))
  returning id, taken_at into sid, taken;
  update tracking.submissions set last_snapshot_at = taken, last_views = p_views where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', s.status = 'flagged', 'locked', fin);
end $$;

-- Post dihapus/diprivate sebelum lock (§11, FR-06): admin menghanguskan earning pending + notifikasi (event submission.post_gone).
create function api.worker_post_gone(p_submission uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s tracking.submissions;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return;
  end if;
  update tracking.submissions set lease_until = 'infinity' where id = s.id;  -- tidak dipoll lagi sambil menunggu status admin
  perform bus.emit('admin', 'submission.post_gone', jsonb_build_object('submission_id', s.id, 'reason', p_reason));
end $$;

-- Status token akun sosmed: expired/revoked → tracking submisinya berhenti (enqueue hanya akun verified) + notifikasi sekali;
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
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.notify(a.user_id, 'social.token_expired',
                         jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle,
                                            'paused_count', tracking.paused_count(a.id)));
    end if;
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
  -- FOR SHARE: serial dengan penutupan akun (status closed + profile.anonymize) — akun & token tidak tersimpan sesudah dibersihkan.
  perform 1 from market.profiles pr where pr.id = p_user for share;
  -- Aktif efektif (sama dengan claim_check / require_active_clipper): suspend yang sudah lewat tidak menunggu job lifecycle.
  if not exists (select 1 from market.profiles pr where pr.id = p_user
                  and (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now()))) then
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
  return aid;
end $$;

-- Submit video (E-12, F-C06) setelah creator/social memverifikasi kepemilikan lewat API platform. Kode error (P0001):
-- profile_inactive, claim_not_open, not_your_claim, campaign_closed, account_not_yours, account_inactive, platform_not_allowed,
-- posted_before_claim, missing_tags:<daftar>, duration_out_of_range, already_submitted, reused_video, invalid:url.
-- Claim & campaign = replika admin/brand di creator. Admin memutus status saat replika submisi tiba (review_route: auto →
-- tracking, manual → in_review), menandai claim submitted, FR-07, notifikasi brand. Status di respons = hasil keputusan itu.
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
  route text;
begin
  -- Aktif efektif (sama dengan claim_check / require_active_clipper): suspend yang sudah lewat tidak menunggu job lifecycle.
  if not exists (select 1 from market.profiles pr where pr.id = p_user
                  and (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now()))) then
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
    insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at, duration_sec,
                                      review_route, cover_hash)
    values (cl.id, p_user, c.id, a.id, a.platform, p_post_id, p_url, p_posted_at, p_duration_sec,
            -- §11: API TikTok tidak memberi info sound → campaign musik/sound di TikTok selalu diverifikasi manual.
            case when c.review_mode in ('manual', 'brand')
                      or (p_duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))
                      or (c.type = 'music' and a.platform = 'tiktok')
                 then 'manual' else 'auto' end,
            p_cover_hash)
    returning id, review_route into sid, route;
  exception when unique_violation then
    raise exception 'already_submitted' using errcode = 'P0001';
  end;
  return jsonb_build_object('submission_id', sid, 'status', case route when 'auto' then 'tracking' else 'in_review' end);
end $$;

-- Cek caption terhadap brief (F-C06, §11): mengembalikan yang kurang, mis. {'#mplid','@studiosatu','https://studio.id/promo'};
-- '{}' = lengkap; NULL = campaign tidak ada. Sama dengan admin api.missing_brief_tags (app & fraud FR-06), di sini untuk
-- Edge Function creator/social (daftar video & submit) atas replika campaign.
create function api.missing_brief_tags(p_campaign uuid, p_caption text) returns text[]
language plpgsql stable security definer set search_path = '' as $$
declare
  c record;
  cap text := lower(coalesce(p_caption, ''));
  tags text[];
  handles text[];
  missing text[] := '{}';
  x text;
begin
  select required_hashtags, required_mentions, required_links into c from market.campaigns where id = p_campaign;
  if not found then
    return null;
  end if;
  select coalesce(array_agg(m[1]), '{}') into tags from regexp_matches(cap, '#([[:alnum:]_]+)', 'g') m;
  select coalesce(array_agg(rtrim(m[1], '.')), '{}') into handles from regexp_matches(cap, '@([[:alnum:]_.]+)', 'g') m;
  foreach x in array c.required_hashtags loop
    if not (x = any (tags)) then
      missing := missing || ('#' || x);
    end if;
  end loop;
  foreach x in array c.required_mentions loop
    if not (x = any (handles)) then
      missing := missing || ('@' || x);
    end if;
  end loop;
  foreach x in array c.required_links loop
    if position(lower(regexp_replace(regexp_replace(x, '^https://(www\.)?', ''), '/+$', '')) in cap) = 0 then
      missing := missing || x;
    end if;
  end loop;
  return missing;
end $$;

revoke execute on function api.worker_dequeue(text, int, int), api.worker_retry_later(text, bigint, int, uuid), api.worker_ack(text, bigint),
  tracking.final_due(uuid), api.worker_submission_context(uuid), api.worker_account_token(uuid), api.worker_defer(uuid, timestamptz),
  api.worker_record_snapshot(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb), api.worker_post_gone(uuid, text),
  api.worker_account_status(uuid, text), api.worker_accounts_to_refresh(interval),
  api.worker_upsert_social_account(uuid, text, text, text, int, timestamptz, text),
  api.worker_create_submission(uuid, uuid, uuid, text, text, timestamptz, text, int, bigint), api.missing_brief_tags(uuid, text)
  from public, anon, authenticated;
grant execute on function api.worker_dequeue(text, int, int), api.worker_retry_later(text, bigint, int, uuid), api.worker_ack(text, bigint),
  api.worker_submission_context(uuid), api.worker_account_token(uuid), api.worker_defer(uuid, timestamptz),
  api.worker_record_snapshot(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb), api.worker_post_gone(uuid, text),
  api.worker_account_status(uuid, text), api.worker_accounts_to_refresh(interval),
  api.worker_upsert_social_account(uuid, text, text, text, int, timestamptz, text),
  api.worker_create_submission(uuid, uuid, uuid, text, text, timestamptz, text, int, bigint), api.missing_brief_tags(uuid, text) to service_role;
