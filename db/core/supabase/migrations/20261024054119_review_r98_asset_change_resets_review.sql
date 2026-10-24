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
    perform market.require_resubmit(c);
  end if;  -- status sesudah disetujui: isi dibekukan (market.campaign_content_frozen), versi tidak naik
exception when others then
  perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', p_row ->> 'id', 'error', sqlerrm));
end $function$;

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
  select * into c from market.campaigns k where k.id = coalesce(new.campaign_id, old.campaign_id) for update;
  if c.status = 'in_review' then
    begin  -- applying dimatikan sementara: status draft ikut direplika ke brand & creator; tidak pernah raise (antrean jalan)
      perform set_config('bus.applying', 'off', true);
      perform market.require_resubmit(c);
      perform set_config('bus.applying', 'on', true);
    exception when others then
      perform set_config('bus.applying', 'on', true);
      perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', c.id, 'error', sqlerrm));
    end;
    return coalesce(new, old);
  end if;
  if c.status in ('draft', 'rejected') or c.submitted_version is null then
    return coalesce(new, old);
  end if;
  perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', c.id, 'status', c.status, 'asset', lower(tg_op)));
  return null;
end $function$;

CREATE OR REPLACE FUNCTION market.require_resubmit (
  c market.campaigns
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  update market.campaigns set status = 'rejected' where id = c.id;
  update market.campaigns set status = 'draft' where id = c.id;
  update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
  perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.rejected',
                            jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', 'content_changed'));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (null, 'campaign.resubmit_required', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
          jsonb_build_object('content_version', c.content_version));
end $function$;

REVOKE ALL ON FUNCTION "market"."require_resubmit"(market.campaigns) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."require_resubmit"(market.campaigns) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."require_resubmit"(market.campaigns) TO "postgres";
