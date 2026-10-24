SET local check_function_bodies = off;

DROP FUNCTION "bus_in"."profile_anonymize"(jsonb);

CREATE EXTENSION IF NOT EXISTS "pgmq";

CREATE TABLE "market"."campaigns" (
  "id"                    uuid                     NOT NULL,
  "org_id"                uuid,
  "title"                 text,
  "type"                  text,
  "platforms"             market.platform[],
  "required_hashtags"     text[],
  "required_mentions"     text[],
  "required_links"        text[],
  "min_duration_sec"      smallint,
  "max_duration_sec"      smallint,
  "review_mode"           text,
  "min_followers"         integer,
  "min_account_age_days"  smallint,
  "max_clips_per_clipper" smallint,
  "allow_video_reuse"     boolean,
  "submit_deadline"       timestamp with time zone,
  "view_window_days"      smallint,
  CONSTRAINT "campaigns_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."campaigns"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."claims" (
  "id"          uuid                     NOT NULL,
  "campaign_id" uuid                     NOT NULL,
  "user_id"     uuid                     NOT NULL,
  "expires_at"  timestamp with time zone NOT NULL,
  "created_at"  timestamp with time zone NOT NULL,
  CONSTRAINT "claims_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."claims"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."social_accounts" (
  "id"                  uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"             uuid                     NOT NULL,
  "platform"            market.platform          NOT NULL,
  "external_id"         text                     NOT NULL,
  "handle"              text                     NOT NULL,
  "token_ref"           uuid,
  "status"              text                     NOT NULL DEFAULT 'verified'::text,
  "followers"           integer,
  "platform_created_at" timestamp with time zone,
  "verified_at"         timestamp with time zone NOT NULL DEFAULT now(),
  "created_at"          timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "social_accounts_followers_check" CHECK ((followers >= 0)),
  CONSTRAINT "social_accounts_key" UNIQUE (id, user_id, platform),
  CONSTRAINT "social_accounts_one_owner" UNIQUE (platform, external_id),
  CONSTRAINT "social_accounts_pkey" PRIMARY KEY (id),
  CONSTRAINT "social_accounts_status_check" CHECK ((status = ANY (ARRAY['verified'::text, 'token_expired'::text, 'revoked'::text, 'disconnected'::text])))
);

ALTER TABLE "tracking"."social_accounts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."submissions" (
  "id"                uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "claim_id"          uuid                     NOT NULL,
  "user_id"           uuid                     NOT NULL,
  "campaign_id"       uuid                     NOT NULL,
  "social_account_id" uuid                     NOT NULL,
  "platform"          market.platform          NOT NULL,
  "post_id"           text                     NOT NULL,
  "url"               text                     NOT NULL,
  "posted_at"         timestamp with time zone NOT NULL,
  "duration_sec"      integer,
  "review_route"      text                     NOT NULL,
  "cover_hash"        bigint,
  "last_snapshot_at"  timestamp with time zone,
  "last_views"        bigint,
  "lease_until"       timestamp with time zone,
  "retry_after"       timestamp with time zone,
  "created_at"        timestamp with time zone NOT NULL DEFAULT now(),
  "counted_views"     bigint                   NOT NULL DEFAULT 0,
  "locked_at"         timestamp with time zone,
  "next_poll_at"      timestamp with time zone,
  CONSTRAINT "submissions_last_views_check" CHECK ((last_views >= 0)),
  CONSTRAINT "submissions_one_per_claim" UNIQUE (claim_id),
  CONSTRAINT "submissions_one_post_per_campaign" UNIQUE (campaign_id, platform, post_id),
  CONSTRAINT "submissions_pkey" PRIMARY KEY (id),
  CONSTRAINT "submissions_review_route_check" CHECK ((review_route = ANY (ARRAY['auto'::text, 'manual'::text]))),
  CONSTRAINT "submissions_url_check" CHECK ((url ~ '^https://'::text))
);

ALTER TABLE "tracking"."submissions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."view_snapshots" (
  "id"            bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "submission_id" uuid                     NOT NULL,
  "taken_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "views"         bigint                   NOT NULL,
  "likes"         bigint,
  "comments"      bigint,
  "shares"        bigint,
  "is_final"      boolean                  NOT NULL DEFAULT false,
  "raw"           jsonb,
  CONSTRAINT "view_snapshots_comments_check" CHECK ((comments >= 0)),
  CONSTRAINT "view_snapshots_likes_check" CHECK ((likes >= 0)),
  CONSTRAINT "view_snapshots_pkey" PRIMARY KEY (id),
  CONSTRAINT "view_snapshots_shares_check" CHECK ((shares >= 0)),
  CONSTRAINT "view_snapshots_unique" UNIQUE (submission_id, taken_at),
  CONSTRAINT "view_snapshots_views_check" CHECK ((views >= 0))
);

ALTER TABLE "tracking"."view_snapshots"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "market"."campaign_status" AS ENUM (
  'draft',
  'in_review',
  'cancelled',
  'scheduled',
  'rejected',
  'live',
  'paused',
  'tracking',
  'exhausted',
  'settling',
  'settled'
);

ALTER TABLE "market"."campaigns"
  ADD COLUMN "status" market.campaign_status;

CREATE TYPE "market"."claim_status" AS ENUM (
  'open',
  'submitted',
  'expired',
  'released'
);

ALTER TABLE "market"."claims"
  ADD COLUMN "status" market.claim_status NOT NULL;

CREATE TYPE "tracking"."submission_status" AS ENUM (
  'validating',
  'in_review',
  'tracking',
  'rejected',
  'flagged',
  'forfeited',
  'locked',
  'appealed',
  'settled',
  'rejected_final'
);

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "status" tracking.submission_status NOT NULL DEFAULT 'validating'::tracking.submission_status;

CREATE OR REPLACE FUNCTION api.missing_brief_tags (
  p_campaign uuid,
  p_caption  text
)
  RETURNS text[]
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.store_social_token (
  p_account_id uuid,
  p_token      text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sid uuid;
  st text;
begin
  select a.token_ref, a.status into sid, st from tracking.social_accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'akun sosmed % tidak ada', p_account_id using errcode = 'P0002';
  end if;
  -- Akun dicabut (reset admin / izin dicabut) atau diputus hanya hidup lagi lewat sambung ulang pemilik (upsert → verified dulu);
  -- refresh token yang sedang jalan tidak boleh menulis token baru (R34-1).
  if st not in ('verified', 'token_expired') then
    return null;
  end if;
  if sid is null then
    sid := vault.create_secret(p_token, 'social:' || p_account_id::text, 'token OAuth sosmed');
    update tracking.social_accounts set token_ref = sid where id = p_account_id;
  else
    perform vault.update_secret(sid, p_token);
  end if;
  update tracking.social_accounts set status = 'verified', verified_at = now()
   where id = p_account_id and status in ('token_expired', 'verified');
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_status (
  p_account uuid,
  p_status  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_token (
  p_account uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_accounts_to_refresh (
  p_within interval
)
  RETURNS TABLE (
    account_id uuid,
    platform   market.platform,
    token      text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if p_queue is null or p_queue not in ('tracking') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.delete(p_queue, p_msg_id);
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_defer (
  p_submission uuid,
  p_until      timestamp with time zone
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  if p_queue is null or p_queue not in ('tracking') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message, q.read_ct
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_retry_later (
  p_queue      text,
  p_msg_id     bigint,
  p_seconds    integer,
  p_submission uuid    DEFAULT NULL::uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_submission_context (
  p_submission uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.worker_upsert_social_account (
  p_user                uuid,
  p_platform            text,
  p_external_id         text,
  p_handle              text,
  p_followers           integer,
  p_platform_created_at timestamp with time zone,
  p_token               text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pf market.platform := p_platform::market.platform;
  a tracking.social_accounts;
  aid uuid;
begin
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
end $function$;

CREATE OR REPLACE FUNCTION bus_in.profile_anonymize (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
begin
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 12), display_name = 'Akun dihapus', avatar_path = null
   where id = v_user;
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = v_user);
  delete from tracking.social_accounts a
   where a.user_id = v_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = v_user;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.social_reset (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
begin
  select * into a from tracking.social_accounts x where x.id = (p ->> 'account_id')::uuid for update;
  if not found or a.status = 'disconnected' then
    return;
  end if;
  delete from vault.secrets v where v.id = a.token_ref;
  update tracking.social_accounts set status = 'revoked', token_ref = null where id = a.id;
  perform ops.notify(a.user_id, 'social.token_expired', jsonb_build_object('account_id', a.id, 'platform', a.platform,
                                                                          'handle', a.handle, 'paused_count', tracking.paused_count(a.id)));
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_ref (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'org_id', c.org_id)
                     from market.campaigns c where c.id = p_campaign), '{}');
end $function$;

CREATE OR REPLACE FUNCTION ops.cfg (
  p_key     text,
  p_default jsonb DEFAULT NULL::jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select s.value from ops.settings s where s.key = p_key), p_default);
end $function$;

CREATE OR REPLACE FUNCTION ops.invoke_function (
  p_name text,
  p_body jsonb DEFAULT '{}'::jsonb
)
  RETURNS bigint
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'creator_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'creator_secret_key')));
$function$;

CREATE OR REPLACE FUNCTION ops.notify (
  p_user    uuid,
  p_event   text,
  p_payload jsonb,
  p_email   boolean DEFAULT true
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select bus.emit('admin', 'notify.user', jsonb_build_object('user_id', p_user, 'event', p_event, 'payload', p_payload, 'email', p_email));
$function$;

CREATE OR REPLACE FUNCTION ops.reject_mutation()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $function$;

CREATE OR REPLACE FUNCTION tracking.check_account_limit()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  n int;
  max_n int := coalesce((select (s.value #>> '{}')::int from ops.settings s
                         where s.key = 'public.market.max_accounts_per_platform'), 3);
begin
  -- Hanya yang menambah akun aktif yang dibatasi (insert, disconnected → aktif, pindah user/platform). Perubahan status di antara
  -- verified/token_expired/revoked tidak menambah akun, jadi tetap jalan walau batas config diturunkan (R36-1).
  if tg_op = 'UPDATE' and old.status <> 'disconnected' and old.user_id = new.user_id and old.platform = new.platform then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text || ':' || new.platform::text, 0));
  select count(*) into n from tracking.social_accounts a
   where a.user_id = new.user_id and a.platform = new.platform and a.status <> 'disconnected' and a.id <> new.id;
  if n >= max_n then
    raise exception 'maksimal % akun % per clipper', max_n, new.platform using errcode = '23514';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION tracking.enqueue_due_submissions (
  p_limit integer DEFAULT 500
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int := 0;
  s record;
begin
  for s in update tracking.submissions t set lease_until = now() + interval '1 hour'
            where t.id in (select d.id from tracking.submissions d
                             join tracking.social_accounts a on a.id = d.social_account_id and a.status = 'verified'
                           where d.status in ('tracking', 'flagged') and d.next_poll_at <= now()
                             and (d.lease_until is null or d.lease_until <= now())
                             and (d.retry_after is null or d.retry_after <= now())
                           order by d.next_poll_at limit p_limit for update of d skip locked)
            returning t.id, t.platform loop
    perform pgmq.send('tracking', jsonb_build_object('submission_id', s.id, 'platform', s.platform));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION tracking.final_due (
  p_submission uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
                 where s.id = p_submission
                   and (s.posted_at + make_interval(days => c.view_window_days) <= now()
                        or c.status in ('exhausted', 'settling', 'settled')))
     and not exists (select 1 from tracking.view_snapshots v where v.submission_id = p_submission and v.is_final);
end $function$;

CREATE OR REPLACE FUNCTION tracking.paused_count (
  p_account uuid
)
  RETURNS integer
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select count(*)::int from tracking.submissions s where s.social_account_id = p_account and s.status in ('tracking', 'flagged');
$function$;

ALTER TABLE "tracking"."social_accounts"
  ADD CONSTRAINT "social_accounts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_account_fk" FOREIGN KEY (social_account_id, user_id, platform) REFERENCES tracking.social_accounts(id, user_id, platform);

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "tracking"."view_snapshots"
  ADD CONSTRAINT "view_snapshots_submission_id_fkey" FOREIGN KEY (submission_id) REFERENCES tracking.submissions(id);

CREATE VIEW "api"."claims" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    user_id,
    status,
    expires_at,
    created_at
   FROM market.claims;

CREATE INDEX claims_user_idx ON market.claims USING btree (user_id);

CREATE INDEX social_accounts_user_idx ON tracking.social_accounts USING btree (user_id, platform);

CREATE INDEX submissions_account_idx ON tracking.submissions USING btree (social_account_id, user_id, platform);

CREATE INDEX submissions_campaign_idx ON tracking.submissions USING btree (campaign_id, user_id);

CREATE INDEX submissions_due_idx ON tracking.submissions USING btree (next_poll_at)
  WHERE (status = ANY (ARRAY['tracking'::tracking.submission_status, 'flagged'::tracking.submission_status]));

CREATE INDEX submissions_post_idx ON tracking.submissions USING btree (platform, post_id);

CREATE INDEX submissions_user_idx ON tracking.submissions USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX view_snapshots_one_final ON tracking.view_snapshots USING btree (submission_id)
  WHERE is_final;

CREATE TRIGGER social_accounts_limit
  BEFORE INSERT OR UPDATE OF user_id, platform, status ON tracking.social_accounts
  FOR EACH ROW
  WHEN ((new.status <> 'disconnected'::text))
  EXECUTE FUNCTION tracking.check_account_limit();

CREATE TRIGGER social_accounts_replicate
  AFTER INSERT OR DELETE OR UPDATE ON tracking.social_accounts
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:user_id,platform,external_id,handle,status,followers,platform_created_at,verified_at,created_at');

CREATE TRIGGER submissions_replicate
  AFTER INSERT OR DELETE OR UPDATE ON tracking.submissions
  FOR EACH ROW
  EXECUTE FUNCTION
    bus.replicate('admin:claim_id,user_id,campaign_id,social_account_id,platform,post_id,url,posted_at,duration_sec,review_route,cover_hash,last_snapshot_at,last_views,created_at');

CREATE TRIGGER view_snapshots_append_only
  BEFORE DELETE OR UPDATE ON tracking.view_snapshots
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE TRIGGER view_snapshots_replicate
  AFTER INSERT ON tracking.view_snapshots
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:submission_id,taken_at,views,likes,comments,shares,is_final,raw');

CREATE POLICY "campaigns_iss" ON "market"."campaigns"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "claims_iss" ON "market"."claims"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "claims_own_read" ON "market"."claims"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "social_accounts_admin_read" ON "tracking"."social_accounts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_moderator'::text, 'admin_support'::text]) AS has_admin));

CREATE POLICY "social_accounts_iss" ON "tracking"."social_accounts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "social_accounts_own_read" ON "tracking"."social_accounts"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "submissions_iss" ON "tracking"."submissions"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "submissions_own_read" ON "tracking"."submissions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "view_snapshots_iss" ON "tracking"."view_snapshots"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "view_snapshots_visible" ON "tracking"."view_snapshots"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM tracking.submissions s
  WHERE (s.id = view_snapshots.submission_id))));

COMMENT ON EXTENSION "pgmq" IS 'A lightweight message queue. Like AWS SQS and RSMQ but on Postgres.';

REVOKE ALL ON FUNCTION "api"."missing_brief_tags"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."missing_brief_tags"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."missing_brief_tags"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."missing_brief_tags"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."store_social_token"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."store_social_token"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_social_token"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_social_token"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_account_status"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_account_status"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_status"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_status"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_account_token"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_account_token"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_token"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_token"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_accounts_to_refresh"(interval) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_accounts_to_refresh"(interval) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_accounts_to_refresh"(interval) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_accounts_to_refresh"(interval) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_ack"(text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_ack"(text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_ack"(text, bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_ack"(text, bigint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer, bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer, bigint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_post_gone"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_post_gone"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_post_gone"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_post_gone"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_submission_context"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_submission_context"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_submission_context"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_submission_context"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) TO "service_role";

REVOKE ALL ON FUNCTION "bus_in"."profile_anonymize"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."profile_anonymize"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."profile_anonymize"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."social_reset"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."social_reset"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."social_reset"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_ref"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_ref"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_ref"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."cfg"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."cfg"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."cfg"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."invoke_function"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."invoke_function"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."invoke_function"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."notify"(uuid, text, jsonb, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."notify"(uuid, text, jsonb, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."notify"(uuid, text, jsonb, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."reject_mutation"() TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."check_account_limit"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."check_account_limit"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."check_account_limit"() TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."enqueue_due_submissions"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."enqueue_due_submissions"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."enqueue_due_submissions"(integer) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."final_due"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."final_due"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."final_due"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."paused_count"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."paused_count"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."paused_count"(uuid) TO "postgres";

GRANT SELECT ON TABLE "market"."claims" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("external_id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("followers") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("handle") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("platform_created_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("platform") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("status") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("verified_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ON TABLE "tracking"."submissions" TO "authenticated";

GRANT SELECT ("comments") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("id") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("is_final") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("likes") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("shares") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("submission_id") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("taken_at") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("views") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ON TABLE "api"."claims" TO "authenticated";

SELECT cron.schedule_in_database('token-refresh', '0 */6 * * *', 'select ops.invoke_function(''refresh-tokens'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('track-due', '*/15 * * * *', 'select tracking.enqueue_due_submissions()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('track-worker', '*/5 * * * *', 'select ops.invoke_function(''track-worker'')', 'postgres', NULL, true);

SELECT pgmq.create('tracking');
