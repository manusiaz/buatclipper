SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.campaign_content_frozen()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  frozen jsonb;
begin
  if current_setting('bus.applying', true) is distinct from 'on' or old.status in ('draft', 'in_review', 'rejected')
     or old.submitted_version is null or coalesce(new.content_version, 0) <= old.submitted_version then
    return new;
  end if;
  select jsonb_object_agg(k, to_jsonb(old) -> k) into frozen from unnest(bus.accepts('brand', 'market.campaigns')) k
   where k not in ('faq', 'slug');
  if (select jsonb_object_agg(k, to_jsonb(new) -> k) from jsonb_object_keys(frozen) k) is distinct from frozen then
    new := jsonb_populate_record(new, frozen);
    perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', old.id, 'status', old.status));
  end if;
  return new;
end $function$;
