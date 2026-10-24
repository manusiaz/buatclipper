SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus.accepts (
  p_source text,
  p_table  text
)
  RETURNS text[]
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select v.cols from (values
    ('admin', 'market.campaigns', array['status', 'submit_deadline', 'view_window_days', 'required_hashtags', 'required_mentions', 'required_links']),
    ('admin', 'market.claims', array['campaign_id', 'user_id', 'status', 'expires_at', 'created_at']),
    ('admin', 'market.profiles', array['status', 'suspended_until', 'trust_score']),
    ('admin', 'ops.settings', array['value', 'updated_by', 'updated_at']),
    ('admin', 'tracking.submissions', array['status', 'counted_views', 'locked_at', 'next_poll_at']),
    ('brand', 'market.campaigns', array['org_id', 'title', 'type', 'platforms', 'min_duration_sec', 'max_duration_sec', 'review_mode', 'min_followers', 'min_account_age_days', 'max_clips_per_clipper', 'allow_video_reuse']),
    ('brand', 'market.org_links', array['approved_at', 'revoked_at', 'created_at']),
    ('brand', 'market.org_members', array['role', 'created_at']),
    ('brand', 'market.organizations', array['name', 'is_agency', 'status', 'verified_at', 'created_at'])
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$function$;
