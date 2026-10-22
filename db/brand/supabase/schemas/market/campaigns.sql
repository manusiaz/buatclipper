-- E-06 campaign (pemilik isi: project brand, ditulis api.save_campaign brand). Kolom milik admin (replika, ditulis bus):
-- status (S-01), jadwal (start_at, submit_deadline, view_window_days), pin. Isi direplika ke admin (review, katalog, accrual).
-- content_version naik tiap isi selain FAQ berubah; admin mengajukan (submit) hanya versi yang sudah ia terima.
create table market.campaigns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references market.organizations (id),
  slug text not null check (slug ~ '^[a-z0-9-]{3,80}$'),
  title text not null check (char_length(title) between 3 and 120),
  type text not null check (type in ('clipping', 'ugc', 'music', 'logo', 'text')),
  category_id text references market.categories (id),
  platforms market.platform[] not null check (cardinality(platforms) >= 1),
  brief text not null default '',
  managed_brief text not null default '' check (length(managed_brief) <= 20000),
  required_hashtags text[] not null default '{}',
  required_mentions text[] not null default '{}',
  required_links text[] not null default '{}',
  sponsored_label boolean not null default true,
  min_duration_sec smallint check (min_duration_sec > 0),
  max_duration_sec smallint check (max_duration_sec > 0),
  dos text[] not null default '{}',
  donts text[] not null default '{}',
  example_urls text[] not null default '{}',
  faq jsonb not null default '[]' check (jsonb_typeof(faq) = 'array'),
  service_mode text not null default 'self_serve' check (service_mode in ('self_serve', 'managed')),
  review_mode text not null default 'manual' check (review_mode in ('auto', 'manual', 'brand')),
  min_followers integer not null default 0 check (min_followers >= 0),
  min_account_age_days smallint not null default 0 check (min_account_age_days >= 0),
  min_trust_score smallint not null default 0 check (min_trust_score between 0 and 100),
  kyc_required boolean not null default false,
  min_views integer not null default 1000 check (min_views >= 0),
  max_clips_per_clipper smallint not null default 10 check (max_clips_per_clipper >= 1),
  clipper_quota integer check (clipper_quota >= 1),
  allow_video_reuse boolean not null default false,
  visibility text not null default 'public' check (visibility in ('public', 'invite', 'level')),
  is_template boolean not null default false,
  content_version integer not null default 1,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  -- milik admin (replika)
  status market.campaign_status not null default 'draft',
  start_at timestamptz,
  submit_deadline timestamptz,
  view_window_days smallint not null default 30,
  pinned_until timestamptz,
  constraint campaigns_slug_unique unique (slug),
  constraint campaigns_level_has_threshold check (visibility <> 'level' or min_trust_score > 0),
  constraint campaigns_hashtags_format check (array_position(required_hashtags, null) is null and (cardinality(required_hashtags) = 0
    or array_to_string(required_hashtags, ',') ~ '^[[:lower:][:digit:]_]+(,[[:lower:][:digit:]_]+)*$')),
  constraint campaigns_mentions_format check (array_position(required_mentions, null) is null and (cardinality(required_mentions) = 0
    or array_to_string(required_mentions, ',') ~ '^[[:lower:][:digit:]_.]+(,[[:lower:][:digit:]_.]+)*$')),
  constraint campaigns_links_https check (array_position(required_links, null) is null and (cardinality(required_links) = 0
    or array_to_string(required_links, ' ') ~ '^https://\S+( https://\S+)*$')),
  constraint campaigns_examples_https check (array_position(example_urls, null) is null and (cardinality(example_urls) = 0
    or array_to_string(example_urls, ' ') ~ '^https://\S+( https://\S+)*$')),
  constraint campaigns_duration_range check (min_duration_sec is null or max_duration_sec is null or min_duration_sec <= max_duration_sec)
);
create index campaigns_org_idx on market.campaigns (org_id);
create index campaigns_category_idx on market.campaigns (category_id);
create index campaigns_status_idx on market.campaigns (status);

-- Brief terkunci sejak diajukan (status replika dari admin): yang masih boleh berubah hanya FAQ. Versi isi naik tiap perubahan
-- selain FAQ. Perubahan dari replika (kolom admin) tidak menyentuh isi.
create function market.campaign_content_guard() returns trigger
language plpgsql set search_path = '' as $$
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
end $$;
create trigger campaigns_content_guard before update on market.campaigns
  for each row execute function market.campaign_content_guard();
create trigger campaigns_replicate after insert or update or delete on market.campaigns for each row
  execute function bus.replicate('admin:org_id,slug,title,type,category_id,platforms,brief,managed_brief,required_hashtags,required_mentions,required_links,sponsored_label,min_duration_sec,max_duration_sec,dos,donts,example_urls,faq,service_mode,review_mode,min_followers,min_account_age_days,min_trust_score,kyc_required,min_views,max_clips_per_clipper,clipper_quota,allow_video_reuse,visibility,is_template,content_version,created_by,created_at');

-- E-37 undangan campaign privat (F-B11). Direplika ke admin (cek claim & visibilitas campaign invite).
create table market.campaign_invites (
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  user_id uuid not null,
  invited_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (campaign_id, user_id)
);
create index campaign_invites_user_idx on market.campaign_invites (user_id);
create trigger campaign_invites_replicate after insert or update or delete on market.campaign_invites for each row
  execute function bus.replicate('admin:invited_by,created_at');

create function market.is_invited(p_campaign uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return exists (select 1 from market.campaign_invites i where i.campaign_id = p_campaign and i.user_id = (select auth.uid()));
end $$;
revoke execute on function market.is_invited(uuid) from public;
grant execute on function market.is_invited(uuid) to authenticated;

alter table market.campaign_invites enable row level security;
create policy campaign_invites_iss on market.campaign_invites as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy campaign_invites_own_read on market.campaign_invites for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy campaign_invites_admin_read on market.campaign_invites for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.campaign_invites to authenticated;

alter table market.campaigns enable row level security;
create policy campaigns_iss on market.campaigns as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy campaigns_public_anon on market.campaigns for select to anon  -- policy:core.public-read
  using (status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not is_template and visibility = 'public');
create policy campaigns_public_auth on market.campaigns for select to authenticated  -- policy:core.public-read
  using (status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not is_template
         and (visibility = 'public'
              or (visibility = 'invite' and market.is_invited(id))
              or (visibility = 'level' and exists (select 1 from market.profiles p
                                                   where p.id = (select auth.uid()) and p.trust_score >= campaigns.min_trust_score))));
create policy campaigns_org_read on market.campaigns for select to authenticated using ((select ops.is_org_member(org_id)));  -- policy:core.rls-org
create policy campaigns_admin_read on market.campaigns for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.campaigns to anon, authenticated;

create policy campaign_invites_org_read on market.campaign_invites for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
