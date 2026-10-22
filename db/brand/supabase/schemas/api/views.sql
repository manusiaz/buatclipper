-- View Data API brand (security_invoker: RLS tabel berlaku).
create view api.organizations with (security_invoker = true) as
  select id, name, org_type, legal_name, npwp, address, is_agency, status, verified_at, created_at, updated_at from market.organizations;
create view api.org_members with (security_invoker = true) as
  select org_id, user_id, role, created_at from market.org_members;
create view api.org_invites with (security_invoker = true) as
  select id, org_id, role, expires_at, accepted_by, accepted_at, created_by, created_at from market.org_invites;
create view api.org_links with (security_invoker = true) as
  select agency_org_id, client_org_id, approved_by, approved_at, revoked_at, created_at from market.org_links;
create view api.profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path from market.profiles;
grant select on api.organizations, api.org_members, api.org_invites, api.org_links to authenticated;
grant select on api.profiles to anon, authenticated;

-- Campaign (isi milik brand + status/jadwal replika admin). managed_brief terpisah: hanya anggota org & admin.
create view api.campaigns with (security_invoker = true) as
  select id, org_id, slug, title, type, category_id, platforms, brief, required_hashtags, required_mentions, required_links,
         sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq, service_mode, review_mode, min_followers,
         min_account_age_days, min_trust_score, kyc_required, min_views, max_clips_per_clipper, clipper_quota, allow_video_reuse,
         visibility, is_template, content_version, created_by, created_at, status, start_at, submit_deadline, view_window_days,
         pinned_until
    from market.campaigns;
create view api.managed_briefs with (security_invoker = true) as
  select c.id as campaign_id, c.managed_brief from market.campaigns c
  where c.service_mode = 'managed' and ((select ops.is_org_member(c.org_id)) or (select ops.has_admin()));
create view api.campaign_assets with (security_invoker = true) as
  select id, campaign_id, kind, storage_path, url, size_bytes, audience, created_at from market.campaign_assets;
create view api.campaign_invites with (security_invoker = true) as
  select campaign_id, user_id, invited_by, created_at from market.campaign_invites;
create view api.categories with (security_invoker = true) as
  select id, name_id, name_en, sort, active from market.categories;
grant select on api.campaigns, api.campaign_assets, api.categories to anon, authenticated;
grant select on api.campaign_invites, api.managed_briefs to authenticated;
