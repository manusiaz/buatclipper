-- fn:enqueue_notification — tulis notifikasi in-app + antrean email (Supabase Queue "email", dikuras worker notify →
-- bridge identity, alur 4). Email promosi dilewati kalau user mematikannya (E-34). Dipanggil fungsi/job lain, bukan browser.
create function ops.enqueue_notification(p_user uuid, p_event text, p_payload jsonb default '{}', p_email boolean default true)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  nid bigint;
  promo boolean := p_event in ('campaign.new', 'broadcast.sent');
begin
  insert into ops.notifications (user_id, event, payload) values (p_user, p_event, p_payload) returning id into nid;
  if p_email and (not promo or coalesce((select np.email_promotions from ops.notification_prefs np
                                          where np.user_id = p_user), true)) then
    perform pgmq.send('email', jsonb_build_object('notification_id', nid, 'user_id', p_user, 'event', p_event,
                                                  'promo', promo));
  end if;
  return nid;
end $$;
revoke execute on function ops.enqueue_notification(uuid, text, jsonb, boolean) from public;

-- Panggil Edge Function core dari pg_cron lewat pg_net. URL & secret key core dibaca dari Vault core
-- (policy:fn-cron-key: worker memeriksa header apikey).
create function ops.invoke_function(p_name text, p_body jsonb default '{}')
returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'core_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'core_secret_key')));
$$;
revoke execute on function ops.invoke_function(text, jsonb) from public;
