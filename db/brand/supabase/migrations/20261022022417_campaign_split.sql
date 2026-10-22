SET local check_function_bodies = off;

CREATE TABLE "market"."campaign_assets" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id"  uuid                     NOT NULL,
  "kind"         text                     NOT NULL,
  "storage_path" text,
  "url"          text,
  "size_bytes"   bigint,
  "audience"     text                     NOT NULL DEFAULT 'clipper'::text,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "campaign_assets_audience_check" CHECK ((audience = ANY (ARRAY['clipper'::text, 'internal'::text]))),
  CONSTRAINT "campaign_assets_cover_public" CHECK (((kind <> 'cover'::text) OR (audience = 'clipper'::text))),
  CONSTRAINT "campaign_assets_internal_folder" CHECK (((storage_path IS NULL) OR ((split_part(storage_path, '/'::text, 3) = 'internal'::text) = (audience = 'internal'::text)))),
  CONSTRAINT "campaign_assets_kind_check" CHECK ((kind = ANY (ARRAY['cover'::text, 'video'::text, 'image'::text, 'audio'::text, 'document'::text, 'link'::text]))),
  CONSTRAINT "campaign_assets_link_is_url" CHECK (((kind = 'link'::text) = (url IS NOT NULL))),
  CONSTRAINT "campaign_assets_one_source" CHECK (((storage_path IS NULL) <> (url IS NULL))),
  CONSTRAINT "campaign_assets_pkey" PRIMARY KEY (id),
  CONSTRAINT "campaign_assets_size_bytes_check" CHECK ((size_bytes >= 0)),
  CONSTRAINT "campaign_assets_url_check" CHECK ((url ~ '^https://'::text))
);

ALTER TABLE "market"."campaign_assets"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."campaign_invites" (
  "campaign_id" uuid                     NOT NULL,
  "user_id"     uuid                     NOT NULL,
  "invited_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "campaign_invites_pkey" PRIMARY KEY (campaign_id, user_id)
);

ALTER TABLE "market"."campaign_invites"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."campaigns" (
  "id"                    uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "org_id"                uuid                     NOT NULL,
  "slug"                  text                     NOT NULL,
  "title"                 text                     NOT NULL,
  "type"                  text                     NOT NULL,
  "category_id"           text,
  "platforms"             market.platform[]        NOT NULL,
  "brief"                 text                     NOT NULL DEFAULT ''::text,
  "managed_brief"         text                     NOT NULL DEFAULT ''::text,
  "required_hashtags"     text[]                   NOT NULL DEFAULT '{}'::text[],
  "required_mentions"     text[]                   NOT NULL DEFAULT '{}'::text[],
  "required_links"        text[]                   NOT NULL DEFAULT '{}'::text[],
  "sponsored_label"       boolean                  NOT NULL DEFAULT true,
  "min_duration_sec"      smallint,
  "max_duration_sec"      smallint,
  "dos"                   text[]                   NOT NULL DEFAULT '{}'::text[],
  "donts"                 text[]                   NOT NULL DEFAULT '{}'::text[],
  "example_urls"          text[]                   NOT NULL DEFAULT '{}'::text[],
  "faq"                   jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "service_mode"          text                     NOT NULL DEFAULT 'self_serve'::text,
  "review_mode"           text                     NOT NULL DEFAULT 'manual'::text,
  "min_followers"         integer                  NOT NULL DEFAULT 0,
  "min_account_age_days"  smallint                 NOT NULL DEFAULT 0,
  "min_trust_score"       smallint                 NOT NULL DEFAULT 0,
  "kyc_required"          boolean                  NOT NULL DEFAULT false,
  "min_views"             integer                  NOT NULL DEFAULT 1000,
  "max_clips_per_clipper" smallint                 NOT NULL DEFAULT 10,
  "clipper_quota"         integer,
  "allow_video_reuse"     boolean                  NOT NULL DEFAULT false,
  "visibility"            text                     NOT NULL DEFAULT 'public'::text,
  "is_template"           boolean                  NOT NULL DEFAULT false,
  "content_version"       integer                  NOT NULL DEFAULT 1,
  "created_by"            uuid                     NOT NULL,
  "created_at"            timestamp with time zone NOT NULL DEFAULT now(),
  "start_at"              timestamp with time zone,
  "submit_deadline"       timestamp with time zone,
  "view_window_days"      smallint                 NOT NULL DEFAULT 30,
  "pinned_until"          timestamp with time zone,
  CONSTRAINT "campaigns_clipper_quota_check" CHECK ((clipper_quota >= 1)),
  CONSTRAINT "campaigns_duration_range" CHECK (((min_duration_sec IS NULL) OR (max_duration_sec IS NULL) OR (min_duration_sec <= max_duration_sec))),
  CONSTRAINT "campaigns_examples_https"
    CHECK
    (((array_position(example_urls, NULL::text) IS NULL) AND ((cardinality(example_urls) = 0) OR (array_to_string(example_urls, ' '::text) ~
    '^https://\S+( https://\S+)*$'::text)))),
  CONSTRAINT "campaigns_faq_check" CHECK ((jsonb_typeof(faq) = 'array'::text)),
  CONSTRAINT "campaigns_hashtags_format"
    CHECK
    (((array_position(required_hashtags, NULL::text) IS NULL) AND ((cardinality(required_hashtags) = 0) OR (array_to_string(required_hashtags, ','::text) ~
    '^[[:lower:][:digit:]_]+(,[[:lower:][:digit:]_]+)*$'::text)))),
  CONSTRAINT "campaigns_level_has_threshold" CHECK (((visibility <> 'level'::text) OR (min_trust_score > 0))),
  CONSTRAINT "campaigns_links_https"
    CHECK
    (((array_position(required_links, NULL::text) IS NULL) AND ((cardinality(required_links) = 0) OR (array_to_string(required_links, ' '::text) ~
    '^https://\S+( https://\S+)*$'::text)))),
  CONSTRAINT "campaigns_managed_brief_check" CHECK ((length(managed_brief) <= 20000)),
  CONSTRAINT "campaigns_max_clips_per_clipper_check" CHECK ((max_clips_per_clipper >= 1)),
  CONSTRAINT "campaigns_max_duration_sec_check" CHECK ((max_duration_sec > 0)),
  CONSTRAINT "campaigns_mentions_format"
    CHECK
    (((array_position(required_mentions, NULL::text) IS NULL) AND ((cardinality(required_mentions) = 0) OR (array_to_string(required_mentions, ','::text) ~
    '^[[:lower:][:digit:]_.]+(,[[:lower:][:digit:]_.]+)*$'::text)))),
  CONSTRAINT "campaigns_min_account_age_days_check" CHECK ((min_account_age_days >= 0)),
  CONSTRAINT "campaigns_min_duration_sec_check" CHECK ((min_duration_sec > 0)),
  CONSTRAINT "campaigns_min_followers_check" CHECK ((min_followers >= 0)),
  CONSTRAINT "campaigns_min_trust_score_check" CHECK (((min_trust_score >= 0) AND (min_trust_score <= 100))),
  CONSTRAINT "campaigns_min_views_check" CHECK ((min_views >= 0)),
  CONSTRAINT "campaigns_pkey" PRIMARY KEY (id),
  CONSTRAINT "campaigns_platforms_check" CHECK ((cardinality(platforms) >= 1)),
  CONSTRAINT "campaigns_review_mode_check" CHECK ((review_mode = ANY (ARRAY['auto'::text, 'manual'::text, 'brand'::text]))),
  CONSTRAINT "campaigns_service_mode_check" CHECK ((service_mode = ANY (ARRAY['self_serve'::text, 'managed'::text]))),
  CONSTRAINT "campaigns_slug_check" CHECK ((slug ~ '^[a-z0-9-]{3,80}$'::text)),
  CONSTRAINT "campaigns_slug_unique" UNIQUE (slug),
  CONSTRAINT "campaigns_title_check" CHECK (((char_length(title) >= 3) AND (char_length(title) <= 120))),
  CONSTRAINT "campaigns_type_check" CHECK ((type = ANY (ARRAY['clipping'::text, 'ugc'::text, 'music'::text, 'logo'::text, 'text'::text]))),
  CONSTRAINT "campaigns_visibility_check" CHECK ((visibility = ANY (ARRAY['public'::text, 'invite'::text, 'level'::text])))
);

ALTER TABLE "market"."campaigns"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."categories" (
  "id"      text     NOT NULL,
  "name_id" text     NOT NULL,
  "name_en" text     NOT NULL,
  "sort"    smallint NOT NULL DEFAULT 0,
  "active"  boolean  NOT NULL DEFAULT true,
  CONSTRAINT "categories_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."categories"
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE "market"."profiles"
  ADD COLUMN "trust_score" smallint NOT NULL DEFAULT 50;

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
  ADD COLUMN "status" market.campaign_status NOT NULL DEFAULT 'draft'::market.campaign_status;

CREATE OR REPLACE FUNCTION api.duplicate_campaign (
  p_campaign    uuid,
  p_as_template boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  nid uuid := gen_random_uuid();
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, brief, required_hashtags, required_mentions,
                                required_links, sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq,
                                review_mode, min_followers, min_account_age_days, min_trust_score, kyc_required,
                                min_views, max_clips_per_clipper, clipper_quota, allow_video_reuse, visibility, is_template, created_by)
  values (nid, c.org_id, left(regexp_replace(c.slug, '-[0-9a-f]{6}$', ''), 72) || '-' || substr(md5(nid::text), 1, 6),
          c.title, c.type, c.category_id, c.platforms, c.brief, c.required_hashtags, c.required_mentions, c.required_links,
          c.sponsored_label, c.min_duration_sec, c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq,
          c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required, c.min_views,
          c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, coalesce(p_as_template, false), uid);
  return nid;
end $function$;

CREATE OR REPLACE FUNCTION api.invite_to_campaign (
  p_campaign  uuid,
  p_usernames text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  pr record;
  n int := 0;
  k int;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template or c.status in ('cancelled', 'rejected', 'settling', 'settled') then
    perform market.fail('invalid_state:' || c.status, 'campaign ini tidak bisa menerima undangan');
  end if;
  if coalesce(cardinality(p_usernames), 0) > 500 then
    perform market.fail('invalid:usernames', 'maks 500 username per panggilan');
  end if;
  for pr in select p.id from market.profiles p
             where p.status = 'active'
               and p.username in (select lower(btrim(ltrim(btrim(u), '@'))) from unnest(p_usernames) u) loop
    insert into market.campaign_invites (campaign_id, user_id, invited_by) values (c.id, pr.id, uid) on conflict do nothing;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      perform ops.enqueue_notification(pr.id, 'campaign.invited',
                                       jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                          'org_id', c.org_id,
                                                          'org_name', (select o.name from market.organizations o where o.id = c.org_id)));
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION api.save_campaign (
  p_campaign jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  p jsonb := coalesce(p_campaign, '{}');
  is_admin boolean := ops.has_admin('admin_ops');
  cols constant text[] := array['title', 'slug', 'type', 'category_id', 'platforms', 'brief', 'managed_brief', 'required_hashtags',
    'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls',
    'faq', 'service_mode', 'review_mode', 'min_followers', 'min_account_age_days', 'min_trust_score', 'kyc_required', 'min_views',
    'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility', 'is_template'];
  c market.campaigns;
  org market.organizations;
  patch jsonb := '{}';
  k text;
  present text[];
  e jsonb;
  kept_assets uuid[] := '{}';
  prefix text;
  aid uuid;
  a_path text;
  a_url text;
begin
  if jsonb_typeof(p) <> 'object' then
    perform market.fail('invalid:payload', 'p_campaign harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (cols) or k in ('id', 'org_id', 'assets')) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into c from market.campaigns where id = (p ->> 'id')::uuid for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if p ? 'org_id' and (p ->> 'org_id')::uuid is distinct from c.org_id then
      perform market.fail('invalid:org_id', 'campaign tidak bisa pindah org');
    end if;
  end if;
  select * into org from market.organizations where id = coalesce(c.org_id, (p ->> 'org_id')::uuid);
  if org.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if not (ops.is_org_member(org.id, 'brand_owner', 'brand_manager') or is_admin) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org atau admin_ops aal2', '42501');
  end if;
  if org.status = 'suspended' then
    perform market.fail('org_suspended', 'org disuspend');
  end if;
  if is_admin then  -- F-A11: builder admin (paket managed) tercatat
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'campaign.save', 'campaign:' || coalesce(p ->> 'id', 'new'), jsonb_build_object('status', c.status),
            jsonb_build_object('keys', (select jsonb_agg(k2 order by k2) from jsonb_object_keys(p) k2)));
  end if;

  -- Sejak diajukan brief terkunci (trigger campaigns_content_guard); di sini hanya FAQ yang diterima.
  if c.id is not null and c.status not in ('draft', 'rejected') then
    if exists (select 1 from jsonb_object_keys(p) x where x not in ('id', 'org_id', 'faq')) then
      perform market.fail('campaign_locked', format('campaign %s: yang bisa diubah hanya faq', c.status));
    end if;
    if p ? 'faq' then
      update market.campaigns set faq = p -> 'faq' where id = c.id returning * into c;
    end if;
    return jsonb_build_object('id', c.id, 'content_version', c.content_version);
  end if;

  for k in select x from jsonb_object_keys(p) x where x = any (cols) loop
    patch := patch || jsonb_build_object(k, p -> k);
  end loop;
  if patch ? 'title' then
    patch := patch || jsonb_build_object('title', btrim(patch ->> 'title'));
  end if;
  if patch ? 'required_hashtags' then
    patch := patch || jsonb_build_object('required_hashtags', market.norm_list(p -> 'required_hashtags', 'hashtag', 'required_hashtags'));
  end if;
  if patch ? 'required_mentions' then
    patch := patch || jsonb_build_object('required_mentions', market.norm_list(p -> 'required_mentions', 'mention', 'required_mentions'));
  end if;
  if patch ? 'required_links' then
    patch := patch || jsonb_build_object('required_links', market.norm_list(p -> 'required_links', 'link', 'required_links'));
  end if;
  if patch ? 'example_urls' then
    patch := patch || jsonb_build_object('example_urls', market.norm_list(p -> 'example_urls', 'link', 'example_urls'));
  end if;
  if patch ? 'dos' then
    patch := patch || jsonb_build_object('dos', market.norm_list(p -> 'dos', 'text', 'dos'));
  end if;
  if patch ? 'donts' then
    patch := patch || jsonb_build_object('donts', market.norm_list(p -> 'donts', 'text', 'donts'));
  end if;
  if patch ? 'slug' then
    patch := patch || jsonb_build_object('slug', lower(btrim(patch ->> 'slug')));
    if (patch ->> 'slug') !~ '^[a-z0-9-]{3,80}$' then
      perform market.fail('invalid:slug', 'slug 3–80 huruf kecil, angka, -');
    end if;
  elsif c.id is null then
    patch := patch || jsonb_build_object('slug',
      left(coalesce(nullif(btrim(regexp_replace(lower(coalesce(patch ->> 'title', '')), '[^a-z0-9]+', '-', 'g'), '-'), ''), 'campaign'), 60)
      || '-' || substr(md5(gen_random_uuid()::text), 1, 6));
  end if;
  if exists (select 1 from market.campaigns x where x.slug = patch ->> 'slug' and x.id is distinct from c.id) then
    perform market.fail('slug_taken', patch ->> 'slug');
  end if;

  select array_agg(x) into present from jsonb_object_keys(patch) x;
  if c.id is null then
    patch := patch || jsonb_build_object('org_id', org.id, 'created_by', uid);
    present := present || array['org_id', 'created_by'];
    execute format('insert into market.campaigns (%1$s) select %1$s from jsonb_populate_record(null::market.campaigns, $1) returning *',
                   (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch into c;
  elsif cardinality(present) > 0 then
    execute format('update market.campaigns t set (%1$s) = (select %1$s from jsonb_populate_record(null::market.campaigns, $1)) '
                   'where t.id = $2', (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch, c.id;
  end if;

  -- Aset (E-10): file wajib di folder {org}/{campaign}/ (internal/ = berkas brief mentah, hanya anggota org + admin).
  if p ? 'assets' then
    if jsonb_typeof(p -> 'assets') <> 'array' then
      perform market.fail('invalid:assets', 'assets harus array');
    end if;
    prefix := org.id::text || '/' || c.id::text || '/';
    for e in select jsonb_array_elements(p -> 'assets') loop
      a_path := nullif(btrim(e ->> 'storage_path'), '');
      a_url := (market.norm_list(case when e ? 'url' then jsonb_build_array(e -> 'url') end, 'link', 'asset_url'))[1];
      if a_path is not null and left(a_path, length(prefix)) <> prefix then
        perform market.fail('invalid:asset_path', format('file harus di folder %s', prefix));
      end if;
      select x.id into aid from market.campaign_assets x
       where x.campaign_id = c.id and (x.storage_path = a_path or x.url = a_url) limit 1;
      if aid is null then
        insert into market.campaign_assets (campaign_id, kind, storage_path, url, size_bytes, audience)
        values (c.id, e ->> 'kind', a_path, a_url, market.jnum(e -> 'size_bytes')::bigint,
                coalesce(e ->> 'audience', case when split_part(a_path, '/', 3) = 'internal' then 'internal' else 'clipper' end))
        returning id into aid;
      end if;
      kept_assets := kept_assets || aid;
    end loop;
    delete from market.campaign_assets where campaign_id = c.id and not (id = any (kept_assets));
  end if;
  select * into c from market.campaigns where id = c.id;
  return jsonb_build_object('id', c.id, 'content_version', c.content_version);
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t regclass := (p ->> 'table')::regclass;
  pk text[] := bus.pk_columns(t);
  cols text[];
  upd text;
  h regprocedure;
begin
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = excluded.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    begin
      execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do %4$s',
                     t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                     (select string_agg(format('%I', c), ', ') from unnest(pk) c),
                     case when upd is null then 'nothing' else 'update set ' || upd end)
        using p -> 'row';
    exception when not_null_violation then
      -- kolom milik sebagian (mis. status dari admin) untuk baris yang belum/tidak ada di sini: tidak ada yang diperbarui
      perform set_config('bus.applying', 'off', true);
      return;
    end;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus.resync (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cols text[];
  pk text[] := bus.pk_columns(p_table);
  r jsonb;
  n int := 0;
begin
  select string_to_array(split_part(a, ':', 2), ',') into cols
    from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target;
  if cols is null then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  for r in execute format('select to_jsonb(t) from %s t', p_table) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert',
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_content_guard()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if current_setting('bus.applying', true) = 'on' then
    return new;
  end if;
  if (to_jsonb(new) - array['faq', 'content_version', 'status', 'start_at', 'submit_deadline', 'view_window_days', 'pinned_until'])
     is distinct from (to_jsonb(old) - array['faq', 'content_version', 'status', 'start_at', 'submit_deadline', 'view_window_days', 'pinned_until']) then
    if old.status not in ('draft', 'rejected') then
      raise exception 'campaign_locked' using errcode = '23514',
        detail = format('brief terkunci sejak diajukan (status %s); yang boleh diubah hanya FAQ', old.status);
    end if;
    new.content_version := old.content_version + 1;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION market.is_invited (
  p_campaign uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from market.campaign_invites i where i.campaign_id = p_campaign and i.user_id = (select auth.uid()));
end $function$;

CREATE OR REPLACE FUNCTION market.jnum (
  p jsonb
)
  RETURNS numeric
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end;
$function$;

CREATE OR REPLACE FUNCTION market.norm_list (
  p       jsonb,
  p_kind  text,
  p_field text
)
  RETURNS text[]
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  res text[] := '{}';
  x text;
  v text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return res;
  end if;
  if jsonb_typeof(p) <> 'array' then
    perform market.fail('invalid:' || p_field, 'harus array');
  end if;
  for x in select jsonb_array_elements_text(p) loop
    v := btrim(x);
    if p_kind = 'hashtag' then
      v := lower(ltrim(v, '#'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_]+$' then
        perform market.fail('invalid:' || p_field, format('hashtag "%s" hanya boleh huruf, angka, _', x));
      end if;
    elsif p_kind = 'mention' then
      v := lower(ltrim(v, '@'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_.]+$' then
        perform market.fail('invalid:' || p_field, format('mention "%s" hanya boleh huruf, angka, _ dan .', x));
      end if;
    elsif p_kind = 'link' and v <> '' then
      if v !~* '^[a-z][a-z0-9+.-]*://' then
        v := 'https://' || v;
      end if;
      if v !~ '^https://\S+$' then
        perform market.fail('invalid:' || p_field, format('link "%s" wajib https', x));
      end if;
    end if;
    if v <> '' and not (v = any (res)) then
      res := res || v;
    end if;
  end loop;
  return res;
end $function$;

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."campaign_assets"
  ADD CONSTRAINT "campaign_assets_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaign_invites"
  ADD CONSTRAINT "campaign_invites_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_category_id_fkey" FOREIGN KEY (category_id) REFERENCES market.categories(id);

CREATE VIEW "api"."campaign_assets" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    kind,
    storage_path,
    url,
    size_bytes,
    audience,
    created_at
   FROM market.campaign_assets;

CREATE VIEW "api"."campaign_invites" WITH (security_invoker=true) AS  SELECT campaign_id,
    user_id,
    invited_by,
    created_at
   FROM market.campaign_invites;

CREATE VIEW "api"."campaigns" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    slug,
    title,
    type,
    category_id,
    platforms,
    brief,
    required_hashtags,
    required_mentions,
    required_links,
    sponsored_label,
    min_duration_sec,
    max_duration_sec,
    dos,
    donts,
    example_urls,
    faq,
    service_mode,
    review_mode,
    min_followers,
    min_account_age_days,
    min_trust_score,
    kyc_required,
    min_views,
    max_clips_per_clipper,
    clipper_quota,
    allow_video_reuse,
    visibility,
    is_template,
    content_version,
    created_by,
    created_at,
    status,
    start_at,
    submit_deadline,
    view_window_days,
    pinned_until
   FROM market.campaigns;

CREATE VIEW "api"."categories" WITH (security_invoker=true) AS  SELECT id,
    name_id,
    name_en,
    sort,
    active
   FROM market.categories;

CREATE VIEW "api"."managed_briefs" WITH (security_invoker=true) AS  SELECT id AS campaign_id,
    managed_brief
   FROM market.campaigns c
  WHERE ((service_mode = 'managed'::text) AND (( SELECT ops.is_org_member(c.org_id) AS is_org_member) OR ( SELECT ops.has_admin() AS has_admin)));

CREATE INDEX campaign_assets_campaign_idx ON market.campaign_assets USING btree (campaign_id);

CREATE INDEX campaign_invites_user_idx ON market.campaign_invites USING btree (user_id);

CREATE INDEX campaigns_category_idx ON market.campaigns USING btree (category_id);

CREATE INDEX campaigns_org_idx ON market.campaigns USING btree (org_id);

CREATE INDEX campaigns_status_idx ON market.campaigns USING btree (status);

CREATE TRIGGER campaign_assets_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaign_assets
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:campaign_id,kind,storage_path,url,size_bytes,audience,created_at');

CREATE TRIGGER campaign_invites_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaign_invites
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:invited_by,created_at');

CREATE TRIGGER campaigns_content_guard
  BEFORE UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION market.campaign_content_guard();

CREATE TRIGGER campaigns_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION
    bus.replicate('admin:org_id,slug,title,type,category_id,platforms,brief,managed_brief,required_hashtags,required_mentions,required_links,sponsored_label,min_duration_sec,max_duration_sec,dos,donts,example_urls,faq,service_mode,review_mode,min_followers,min_account_age_days,min_trust_score,kyc_required,min_views,max_clips_per_clipper,clipper_quota,allow_video_reuse,visibility,is_template,content_version,created_by,created_at');

CREATE POLICY "campaign_assets_cover_public" ON "market"."campaign_assets"
  FOR SELECT
  TO "anon"
  USING (((kind = 'cover'::text) AND (audience = 'clipper'::text) AND (EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE (c.id = campaign_assets.campaign_id)))));

CREATE POLICY "campaign_assets_iss" ON "market"."campaign_assets"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaign_assets_visible" ON "market"."campaign_assets"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE
    ((c.id = campaign_assets.campaign_id) AND ((campaign_assets.audience = 'clipper'::text) OR ( SELECT ops.is_org_member(c.org_id) AS is_org_member) OR ( SELECT ops.has_admin() AS
    has_admin))))));

CREATE POLICY "campaign_invites_admin_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "campaign_invites_iss" ON "market"."campaign_invites"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaign_invites_org_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = campaign_invites.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "campaign_invites_own_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "campaigns_admin_read" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "campaigns_iss" ON "market"."campaigns"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaigns_org_read" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(campaigns.org_id) AS is_org_member));

CREATE POLICY "campaigns_public_anon" ON "market"."campaigns"
  FOR SELECT
  TO "anon"
  USING
    (((status = ANY (ARRAY['live'::market.campaign_status, 'paused'::market.campaign_status, 'tracking'::market.campaign_status, 'exhausted'::market.campaign_status,
    'settling'::market.campaign_status, 'settled'::market.campaign_status])) AND (NOT is_template) AND (visibility = 'public'::text)));

CREATE POLICY "campaigns_public_auth" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING
    (((status = ANY (ARRAY['live'::market.campaign_status, 'paused'::market.campaign_status, 'tracking'::market.campaign_status, 'exhausted'::market.campaign_status,
    'settling'::market.campaign_status,
    'settled'::market.campaign_status])) AND (NOT is_template) AND
    ((visibility = 'public'::text) OR ((visibility = 'invite'::text) AND market.is_invited(id)) OR ((visibility = 'level'::text) AND (EXISTS ( SELECT 1
   FROM market.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND (p.trust_score >= campaigns.min_trust_score))))))));

CREATE POLICY "categories_iss" ON "market"."categories"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "categories_public_read" ON "market"."categories"
  FOR SELECT
  TO "anon", "authenticated"
  USING (active);

CREATE POLICY "campaign_assets_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'campaign-assets'::text) AND (EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE
    ((c.id = ((storage.foldername(objects.name))[2])::uuid) AND (((storage.foldername(objects.name))[3] IS DISTINCT FROM 'internal'::text) OR ( SELECT ops.is_org_member(c.org_id)
    AS is_org_member) OR ( SELECT ops.has_admin() AS has_admin)))))));

CREATE POLICY "campaign_files_write" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH
    CHECK
    (((bucket_id = ANY (ARRAY['campaign-covers'::text, 'campaign-assets'::text])) AND (( SELECT ops.is_org_member(((storage.foldername(objects.name))[1])::uuid, VARIADIC
    ARRAY['brand_owner'::market.org_role, 'brand_manager'::market.org_role]) AS is_org_member) OR ( SELECT ops.has_admin(VARIADIC ARRAY['admin_ops'::text]) AS has_admin))));

REVOKE ALL ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) TO "postgres";

REVOKE ALL ON FUNCTION "api"."save_campaign"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_campaign"(jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_campaign"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_campaign"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."resync"(regclass, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."resync"(regclass, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."resync"(regclass, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_content_guard"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_content_guard"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_content_guard"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."is_invited"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "market"."is_invited"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "market"."is_invited"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."is_invited"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."jnum"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."jnum"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."jnum"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."norm_list"(jsonb, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."norm_list"(jsonb, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."norm_list"(jsonb, text, text) TO "postgres";

GRANT SELECT ON TABLE "market"."campaign_assets" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."campaign_invites" TO "authenticated";

GRANT SELECT ON TABLE "market"."campaigns" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."categories" TO "anon", "authenticated";

REVOKE ALL ("trust_score") ON TABLE "market"."profiles" FROM "authenticated";

GRANT SELECT ("trust_score") ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ON TABLE "api"."campaign_assets" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."campaign_invites" TO "authenticated";

GRANT SELECT ON TABLE "api"."campaigns" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."categories" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."managed_briefs" TO "authenticated";
