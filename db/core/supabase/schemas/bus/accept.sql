-- DIBANGKITKAN scripts/gen-bus-accept.mjs dari trigger bus.replicate pengirim — jangan diedit tangan.
-- Kolom yang boleh ditulis tiap pengirim lewat rep.row di DB ini (bus.apply_row); selain itu ditolak.
create function bus.accepts(p_source text, p_table text) returns text[]
language sql immutable set search_path = '' as $$
  select v.cols from (values
    ('brand', 'market.campaign_assets', array['campaign_id', 'kind', 'storage_path', 'url', 'size_bytes', 'audience', 'created_at']),
    ('brand', 'market.campaign_invites', array['invited_by', 'created_at']),
    ('brand', 'market.campaigns', array['org_id', 'slug', 'title', 'type', 'category_id', 'platforms', 'brief', 'managed_brief', 'required_hashtags', 'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls', 'faq', 'service_mode', 'review_mode', 'min_followers', 'min_account_age_days', 'min_trust_score', 'kyc_required', 'min_views', 'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility', 'is_template', 'content_version', 'created_by', 'created_at']),
    ('brand', 'market.org_links', array['approved_by', 'approved_at', 'revoked_at', 'created_at']),
    ('brand', 'market.org_members', array['role', 'added_by', 'created_at']),
    ('brand', 'market.organizations', array['name', 'org_type', 'legal_name', 'npwp', 'address', 'is_agency', 'status', 'verified_by', 'verified_at', 'created_by', 'created_at', 'updated_at']),
    ('creator', 'market.profiles', array['username', 'display_name', 'avatar_path', 'created_at']),
    ('creator', 'tracking.social_accounts', array['user_id', 'platform', 'external_id', 'handle', 'status', 'followers', 'platform_created_at', 'verified_at', 'created_at']),
    ('creator', 'tracking.submissions', array['claim_id', 'user_id', 'campaign_id', 'social_account_id', 'platform', 'post_id', 'url', 'posted_at', 'duration_sec', 'review_route', 'cover_hash', 'last_snapshot_at', 'last_views', 'created_at']),
    ('creator', 'tracking.view_snapshots', array['submission_id', 'taken_at', 'views', 'likes', 'comments', 'shares', 'is_final', 'raw'])
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$$;
-- Topik selain rep.row yang boleh dikirim tiap pengirim ke DB ini (bus.emit di kode pengirim).
create function bus.accepts_topic(p_source text, p_topic text) returns boolean
language sql immutable set search_path = '' as $$
  select (p_source, p_topic) in (
    ('brand', 'audit.log'),
    ('brand', 'bus.ping'),
    ('brand', 'bus.rejected'),
    ('brand', 'notify.user'),
    ('brand', 'org.owner_lost'),
    ('brand', 'review.decision'),
    ('creator', 'bus.ping'),
    ('creator', 'bus.rejected'),
    ('creator', 'notify.user'),
    ('creator', 'referral.record'),
    ('creator', 'submission.post_gone')
  );
$$;
revoke execute on function bus.accepts(text, text), bus.accepts_topic(text, text) from public;
