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
  -- versi lain dari yang diajukan (lebih baru, atau lebih lama sesudah brand dipulihkan dari backup, O8-C1) = isi bukan yang direview
  if c.id is null or c.content_version = coalesce(c.submitted_version, 0) then
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

CREATE OR REPLACE FUNCTION market.campaign_content_frozen()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  frozen jsonb;
begin
  if current_setting('bus.applying', true) is distinct from 'on' or old.status in ('draft', 'in_review', 'rejected')
     or old.submitted_version is null or coalesce(new.content_version, 0) = old.submitted_version then
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
