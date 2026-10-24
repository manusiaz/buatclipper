SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.campaign_assets_frozen()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
begin
  -- BEFORE INSERT jalan sebelum ON CONFLICT: aset yang sudah ada (putar ulang identik, mis. bus.resync) bukan perubahan
  if current_setting('bus.applying', true) is distinct from 'on'
     or (tg_op = 'INSERT' and exists (select 1 from market.campaign_assets x where x.id = new.id)) then
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
