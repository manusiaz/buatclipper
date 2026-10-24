SET local check_function_bodies = off;

DROP FUNCTION "api"."ensure_profile"(text, text, text);

CREATE OR REPLACE FUNCTION api.ensure_profile (
  p_username      text,
  p_display_name  text,
  p_referral_code text DEFAULT NULL::text,
  p_avatar_path   text DEFAULT NULL::text
)
  RETURNS TABLE (
    id           uuid,
    username     text,
    display_name text,
    created      boolean
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  was_new boolean;
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if p_avatar_path is not null and (p_avatar_path not like uid::text || '/%' or p_avatar_path like '%..%') then
    perform market.fail('invalid:avatar_path', 'avatar harus di folder {uid}/', '22023');
  end if;
  begin
    insert into market.profiles as p (id, username, display_name, avatar_path)
    values (uid, lower(btrim(p_username)), btrim(p_display_name), p_avatar_path)
    on conflict on constraint profiles_pkey do update set username = excluded.username, display_name = excluded.display_name,
      avatar_path = coalesce(excluded.avatar_path, p.avatar_path)
      where p.status = 'active'
    returning (xmax = 0) into was_new;
  exception when unique_violation then
    perform market.fail('username_taken', lower(btrim(p_username)), '23505');
  end;
  if was_new is null then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif', '42501');
  end if;
  -- Referral (F-C16) hanya dicatat untuk profil baru; kode tidak dikenal atau milik sendiri diabaikan.
  if was_new and p_referral_code is not null then
    insert into market.referrals (referred_id, referrer_id, code)
    select uid, r.id, r.referral_code from market.profiles r
     where r.referral_code = lower(btrim(p_referral_code)) and r.id <> uid;
  end if;
  return query select pr.id, pr.username, pr.display_name, was_new from market.profiles pr where pr.id = uid;
end $function$;

CREATE OR REPLACE FUNCTION api.invite_preview (
  p_token text
)
  RETURNS TABLE (
    org_name  text,
    is_agency boolean,
    role      text,
    expired   boolean,
    used      boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select o.name, o.is_agency, i.role::text, i.expires_at <= now(), i.accepted_at is not null
    from market.org_invites i join market.organizations o on o.id = i.org_id
   where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
$function$;

CREATE OR REPLACE FUNCTION market.campaign_report (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare
  counted constant tracking.submission_status[] := array['tracking', 'flagged', 'locked', 'settled']::tracking.submission_status[];
begin
  return (
    select jsonb_build_object(
      'campaign', jsonb_build_object('title', c.title, 'status', c.status, 'start_at', c.start_at,
                                     'submit_deadline', c.submit_deadline, 'platforms', c.platforms),
      'views_valid', coalesce((select sum(s.counted_views) from tracking.submissions s
                               where s.campaign_id = c.id and s.status = any (counted)), 0),
      'clips', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.status = any (counted)),
      'clippers', (select count(distinct s.user_id) from tracking.submissions s
                   where s.campaign_id = c.id and s.status = any (counted)),
      'by_platform', coalesce((select jsonb_object_agg(x.platform, x.views)
                               from (select s.platform, sum(s.counted_views) as views from tracking.submissions s
                                     where s.campaign_id = c.id and s.status = any (counted) group by s.platform) x), '{}'::jsonb),
      'budget', coalesce((select jsonb_agg(jsonb_build_object('reward_type', rt.code, 'unit', rt.unit_label, 'decimals', rt.decimals,
                                                              'total', p.total, 'spent', p.allocated))
                          from finance.reward_pools p join market.reward_types rt on rt.id = p.reward_type_id
                          where p.campaign_id = c.id), '[]'::jsonb),
      'top_clips', coalesce((select jsonb_agg(jsonb_build_object('url', t.url, 'platform', t.platform, 'views', t.counted_views))
                             from (select s.url, s.platform, s.counted_views from tracking.submissions s
                                   where s.campaign_id = c.id and s.status = any (counted)
                                   order by s.counted_views desc limit 10) t), '[]'::jsonb))
    from market.campaigns c where c.id = p_campaign);
end $function$;

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."invite_preview"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."invite_preview"(text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."invite_preview"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."invite_preview"(text) TO "postgres";
