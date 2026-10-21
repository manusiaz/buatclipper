SET local check_function_bodies = off;

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "duration_sec" integer;

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
end $function$;

CREATE OR REPLACE FUNCTION trust.auto_approve_overdue()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'public.market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
              and not (c.type = 'music' and s.platform = 'tiktok')  -- §11 sound TikTok wajib diverifikasi manual (R34-2)
              and not (s.duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))  -- durasi wajib dicek manusia (R66)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $function$;
