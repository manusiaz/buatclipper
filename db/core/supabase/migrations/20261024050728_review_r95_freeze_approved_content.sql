SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus_in.market_campaigns_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
begin
  if p_op <> 'upsert' then
    return;
  end if;
  select * into c from market.campaigns where id = (p_row ->> 'id')::uuid for update;
  if c.id is null or c.content_version <= coalesce(c.submitted_version, 0) then
    return;
  end if;
  if c.status = 'rejected' then
    update market.campaigns set status = 'draft' where id = c.id;
  elsif c.status = 'in_review' then
    update market.campaigns set status = 'rejected' where id = c.id;
    update market.campaigns set status = 'draft' where id = c.id;
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.rejected',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', 'content_changed'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.resubmit_required', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version));
  end if;  -- status sesudah disetujui: isi dibekukan (market.campaign_content_frozen), versi tidak naik
exception when others then
  perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', p_row ->> 'id', 'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_content_frozen()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  frozen jsonb;
begin
  if current_setting('bus.applying', true) is distinct from 'on' or old.status in ('draft', 'in_review', 'rejected') then
    return new;
  end if;
  select jsonb_object_agg(k, to_jsonb(old) -> k) into frozen from unnest(bus.accepts('brand', 'market.campaigns')) k where k <> 'faq';
  if (select jsonb_object_agg(k, to_jsonb(new) -> k) from jsonb_object_keys(frozen) k) is distinct from frozen then
    new := jsonb_populate_record(new, frozen);
    perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', old.id, 'status', old.status));
  end if;
  return new;
end $function$;

CREATE TRIGGER campaigns_content_frozen
  BEFORE UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION market.campaign_content_frozen();

REVOKE ALL ON FUNCTION "market"."campaign_content_frozen"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_content_frozen"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_content_frozen"() TO "postgres";
