SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.worker_account_status (
  p_account uuid,
  p_status  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
  new_status text := case p_status when 'expired' then 'token_expired' when 'revoked' then 'revoked' when 'verified' then 'verified' end;
begin
  if new_status is null then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  -- revoked lengket: hanya pulih lewat sambung ulang pemilik (worker_upsert_social_account), bukan hasil refresh/polling yang
  -- sedang jalan — termasuk 'expired' yang akan membuka jalan refresh menulis token lagi (R34-1, R35-1)
  if a.status in ('disconnected', 'revoked') then
    return;
  end if;
  if new_status = 'verified' then
    update tracking.social_accounts set status = 'verified', verified_at = now() where id = a.id;
    update tracking.submissions set next_poll_at = now()
     where social_account_id = a.id and status in ('tracking', 'flagged') and next_poll_at is null;
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                       jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle));
    end if;
    update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  end if;
end $function$;
