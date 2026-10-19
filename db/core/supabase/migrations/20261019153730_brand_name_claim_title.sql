SET local check_function_bodies = off;

DROP FUNCTION "api"."list_campaigns"(jsonb, text);

CREATE OR REPLACE FUNCTION api.campaign_detail (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  staff boolean;
  chk record;
  bud jsonb;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null or not market.campaign_visible(c) then
    perform market.fail('not_found:campaign', 'campaign tidak ada atau tidak terlihat', 'P0002');
  end if;
  staff := ops.is_org_member(c.org_id) or ops.has_admin();
  select * into chk from market.claim_check(c.id);
  bud := market.campaign_budget(c.id);
  return jsonb_build_object(
    'campaign', (select to_jsonb(v) from (select c.id, c.org_id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms,
                   c.brief, c.required_hashtags, c.required_mentions, c.required_links, c.sponsored_label, c.min_duration_sec,
                   c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq, c.service_mode, c.start_at, c.submit_deadline,
                   c.view_window_days, c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required,
                   c.min_views, c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, c.is_template,
                   c.pinned_until, c.pinned_rank, c.created_at, c.fee_rule_id,
                   case when staff then c.managed_brief end as managed_brief) v),
    'brand', (select jsonb_build_object('name', o.name, 'verified', o.status = 'verified') from market.organizations o
               where o.id = c.org_id),
    'rules', bud -> 'rates',
    'pools', bud -> 'pools',
    'budget_idr', bud -> 'budget_idr',
    'remaining_idr', bud -> 'remaining_idr',
    'est_remaining_views', bud -> 'est_remaining_views',
    'assets', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', a.id, 'kind', a.kind, 'audience', a.audience, 'url', a.url, 'size_bytes', a.size_bytes,
                  'storage_path', a.storage_path,
                  'bucket', case when a.storage_path is null then null when a.kind = 'cover' then 'campaign-covers' else 'campaign-assets' end)
                  order by a.kind = 'cover' desc, a.created_at, a.id)
                from market.campaign_assets a where a.campaign_id = c.id and (a.audience = 'clipper' or staff)), '[]'::jsonb),
    'my', jsonb_build_object(
      'claim', (select jsonb_build_object('id', cl.id, 'status', cl.status, 'expires_at', cl.expires_at, 'created_at', cl.created_at)
                  from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
                 order by cl.created_at desc, cl.id limit 1),
      'submissions', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', s.id, 'status', s.status, 'platform', s.platform, 'url', s.url, 'counted_views', s.counted_views,
                         'last_snapshot_at', s.last_snapshot_at, 'created_at', s.created_at,
                         'review', (select jsonb_build_object('decision', d.decision, 'reason_code', d.reason_code, 'message', d.message,
                                                              'at', d.created_at)
                                      from trust.review_decisions d
                                     where d.target_type = 'submission' and d.target_id = s.id and d.decision <> 'appeal'
                                     order by d.created_at desc, d.id desc limit 1),
                         'appeal_used', exists (select 1 from trust.review_decisions d where d.target_type = 'submission'
                                                and d.target_id = s.id and d.decision = 'appeal'))
                         order by s.created_at desc)
                       from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid), '[]'::jsonb),
      'clips_used', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid
                     and s.status not in ('rejected', 'rejected_final'))),
    'cta_state', chk.state,
    'cta_reason', chk.reason);
end $function$;

CREATE OR REPLACE FUNCTION api.list_campaigns (
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_cursor  text  DEFAULT NULL::text
)
  RETURNS TABLE (
    id                  uuid,
    slug                text,
    title               text,
    type                text,
    category_id         text,
    status              market.campaign_status,
    platforms           market.platform[],
    visibility          text,
    start_at            timestamp with time zone,
    submit_deadline     timestamp with time zone,
    cover_path          text,
    is_pinned           boolean,
    pinned_rank         smallint,
    is_new              boolean,
    rates               jsonb,
    budget_idr          numeric,
    remaining_idr       numeric,
    est_remaining_views jsonb,
    cta_state           text,
    cta_reason          text,
    brand_name          text,
    brand_verified      boolean,
    next_cursor         text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  f jsonb := coalesce(p_filters, '{}');
  v_sort text := coalesce(f ->> 'sort', 'newest');
  v_limit int := least(greatest(coalesce(market.jnum(f -> 'limit')::int, 20), 1), 50);
  v_q text := nullif(lower(btrim(f ->> 'q')), '');
  v_platform market.platform := nullif(f ->> 'platform', '')::market.platform;
  v_category text := nullif(f ->> 'category', '');
  pub constant market.campaign_status[] := array['live', 'paused', 'tracking', 'exhausted', 'settling', 'settled']::market.campaign_status[];
  v_status market.campaign_status[] := array['live', 'paused']::market.campaign_status[];
  new_days int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.market.new_badge_days'), 3);
  cur text[];
  cg int;
  cr int;
  ck numeric;
  cid uuid;
begin
  if uid is not null and not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if v_sort not in ('newest', 'rate', 'budget', 'deadline') then
    perform market.fail('invalid:sort', v_sort);
  end if;
  if jsonb_typeof(f -> 'status') = 'array' then
    v_status := array(select jsonb_array_elements_text(f -> 'status'))::market.campaign_status[];
  elsif f ->> 'status' = 'all' then
    v_status := pub;
  elsif nullif(f ->> 'status', '') is not null then
    v_status := array[(f ->> 'status')::market.campaign_status];
  end if;
  if p_cursor is not null then
    cur := string_to_array(p_cursor, '|');
    begin
      cg := cur[1]::int; cr := cur[2]::int; ck := cur[3]::numeric; cid := cur[4]::uuid;
    exception when others then
      perform market.fail('invalid:cursor', p_cursor);
    end;
    if cardinality(cur) <> 4 or cid is null then
      perform market.fail('invalid:cursor', p_cursor);
    end if;
  end if;

  return query
  with base as (
    select c.id, c.org_id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms, c.visibility, c.start_at, c.submit_deadline,
           c.created_at, c.pinned_rank, coalesce(c.pinned_until > now(), false) as pinned,
           (select coalesce(sum((pl.total - pl.allocated) * rt.idr_value_per_unit), 0)
              from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
             where pl.campaign_id = c.id) as rem_idr,
           (select max(x.s) from (select sum(market.rule_rate(r.kind, r.params) * rt.idr_value_per_unit) as s
                                    from unnest(c.platforms) pf(p)
                                    join market.rate_rules r on r.campaign_id = c.id and (r.platform is null or r.platform = pf.p)
                                     and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
                                    join market.reward_types rt on rt.id = r.reward_type_id
                                   group by pf.p) x) as rate_idr
      from market.campaigns c
     where c.status = any (v_status) and c.status = any (pub) and not c.is_template
       and (c.visibility = 'public' or market.campaign_visible(c))
       and (v_platform is null or v_platform = any (c.platforms))
       and (v_category is null or c.category_id = v_category)
       and (v_q is null or position(v_q in lower(c.title)) > 0 or ltrim(v_q, '#') = any (c.required_hashtags))
  ), keyed as (
    select b.*, case when b.pinned then 0 else 1 end as g,
           case when b.pinned then coalesce(b.pinned_rank, 32767) else 32767 end::int as r,
           case v_sort when 'newest' then -extract(epoch from coalesce(b.start_at, b.created_at))
                       when 'rate' then -coalesce(b.rate_idr, 0)
                       when 'budget' then -b.rem_idr
                       else coalesce(extract(epoch from b.submit_deadline), 1e12) end as k
      from base b
  ), page as (
    select kk.* from keyed kk
     where p_cursor is null or (kk.g, kk.r, kk.k, kk.id) > (cg, cr, ck, cid)
     order by kk.g, kk.r, kk.k, kk.id
     limit v_limit
  )
  select pg.id, pg.slug, pg.title, pg.type, pg.category_id, pg.status, pg.platforms, pg.visibility, pg.start_at, pg.submit_deadline,
         (select a.storage_path from market.campaign_assets a where a.campaign_id = pg.id and a.kind = 'cover'
           order by a.created_at limit 1),
         pg.pinned, case when pg.pinned then pg.pinned_rank end, coalesce(pg.start_at, pg.created_at) > now() - make_interval(days => new_days),
         bb.bud -> 'rates', (bb.bud ->> 'budget_idr')::numeric, trim_scale(round(pg.rem_idr, 2)), bb.bud -> 'est_remaining_views',
         cc.state, cc.reason, o.name, o.status = 'verified', concat_ws('|', pg.g, pg.r, pg.k, pg.id)
    from page pg
    join market.organizations o on o.id = pg.org_id
    cross join lateral (select market.campaign_budget(pg.id) as bud) bb
    cross join lateral market.claim_check(pg.id) cc
   order by pg.g, pg.r, pg.k, pg.id;
end $function$;

CREATE OR REPLACE FUNCTION market.run_claim_expiry()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c record;
begin
  for c in update market.claims set reminded_at = now()
            where status = 'open' and reminded_at is null and expires_at <= now() + interval '6 hours' and expires_at > now()
            returning id, user_id, campaign_id, expires_at loop
    perform ops.enqueue_notification(c.user_id, 'claim.expiring', market.campaign_ref(c.campaign_id)
                                     || jsonb_build_object('claim_id', c.id, 'expires_at', c.expires_at));
  end loop;
  update market.claims set status = 'expired' where status = 'open' and expires_at <= now();
end $function$;

REVOKE ALL ON FUNCTION "api"."list_campaigns"(jsonb, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."list_campaigns"(jsonb, text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."list_campaigns"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."list_campaigns"(jsonb, text) TO "postgres";
