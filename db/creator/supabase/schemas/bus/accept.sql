-- DIBANGKITKAN scripts/gen-bus-accept.mjs dari trigger bus.replicate pengirim — jangan diedit tangan.
-- Kolom yang boleh ditulis tiap pengirim lewat rep.row di DB ini (bus.apply_row); selain itu ditolak.
create function bus.accepts(p_source text, p_table text) returns text[]
language sql immutable set search_path = '' as $$
  select v.cols from (values
    ('admin', 'market.campaigns', array['status', 'submit_deadline', 'view_window_days']),
    ('admin', 'market.claims', array['campaign_id', 'user_id', 'status', 'expires_at', 'created_at']),
    ('admin', 'market.profiles', array['status', 'suspended_until', 'trust_score']),
    ('admin', 'ops.settings', array['value', 'updated_by', 'updated_at']),
    ('admin', 'tracking.submissions', array['status', 'counted_views', 'locked_at', 'next_poll_at']),
    ('brand', 'market.campaigns', array['org_id', 'title', 'type', 'platforms', 'required_hashtags', 'required_mentions', 'required_links', 'min_duration_sec', 'max_duration_sec', 'review_mode', 'min_followers', 'min_account_age_days', 'max_clips_per_clipper', 'allow_video_reuse']),
    ('brand', 'market.org_links', array['approved_at', 'revoked_at', 'created_at']),
    ('brand', 'market.org_members', array['role', 'created_at']),
    ('brand', 'market.organizations', array['name', 'is_agency', 'status', 'verified_at', 'created_at'])
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$$;
revoke execute on function bus.accepts(text, text) from public;
