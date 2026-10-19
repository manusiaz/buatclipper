SET local check_function_bodies = off;

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
  v_slug text := nullif(f ->> 'slug', '');  -- halaman publik {domain}/c/[slug]
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
       and (v_slug is null or c.slug = v_slug)
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
