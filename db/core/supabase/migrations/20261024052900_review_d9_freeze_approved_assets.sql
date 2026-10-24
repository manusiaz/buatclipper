SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.campaign_assets_frozen()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
begin
  if current_setting('bus.applying', true) is distinct from 'on' then
    return coalesce(new, old);
  end if;
  select * into c from market.campaigns k where k.id = coalesce(new.campaign_id, old.campaign_id);
  if c.status in ('draft', 'in_review', 'rejected') or c.submitted_version is null then
    return coalesce(new, old);
  end if;
  perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', c.id, 'status', c.status, 'asset', lower(tg_op)));
  return null;
end $function$;

CREATE TRIGGER campaign_assets_frozen
  BEFORE INSERT OR DELETE ON market.campaign_assets
  FOR EACH ROW
  EXECUTE FUNCTION market.campaign_assets_frozen();

REVOKE ALL ON FUNCTION "market"."campaign_assets_frozen"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_assets_frozen"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_assets_frozen"() TO "postgres";
