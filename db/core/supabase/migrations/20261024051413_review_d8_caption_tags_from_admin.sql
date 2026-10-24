DROP TRIGGER "campaigns_replicate" ON "market"."campaigns";

CREATE TRIGGER campaigns_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION
    bus.replicate('brand:status,start_at,submit_deadline,view_window_days,pinned_until',
    'creator:status,submit_deadline,view_window_days,required_hashtags,required_mentions,required_links');
