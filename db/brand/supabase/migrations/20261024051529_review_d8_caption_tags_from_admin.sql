DROP TRIGGER "campaigns_replicate" ON "market"."campaigns";

CREATE TRIGGER campaigns_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION
    bus.replicate('admin:org_id,slug,title,type,category_id,platforms,brief,managed_brief,required_hashtags,required_mentions,required_links,sponsored_label,min_duration_sec,max_duration_sec,dos,donts,example_urls,faq,service_mode,review_mode,min_followers,min_account_age_days,min_trust_score,kyc_required,min_views,max_clips_per_clipper,clipper_quota,allow_video_reuse,visibility,is_template,content_version,created_by,created_at', 'creator:org_id,title,type,platforms,min_duration_sec,max_duration_sec,review_mode,min_followers,min_account_age_days,max_clips_per_clipper,allow_video_reuse');
