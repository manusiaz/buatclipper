-- Helper ops creator: config E-25 (replika admin), panggil Edge Function creator dari pg_cron, notifikasi lewat admin.

-- Nilai config (jsonb) dengan default. Hanya dipanggil fungsi definer.
create function ops.cfg(p_key text, p_default jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select s.value from ops.settings s where s.key = p_key), p_default);
end $$;

-- Panggil Edge Function creator dari pg_cron lewat pg_net. URL & secret key creator dari Vault creator
-- (policy:fn-cron-key: worker memeriksa header apikey).
create function ops.invoke_function(p_name text, p_body jsonb default '{}')
returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'creator_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'creator_secret_key')));
$$;

-- Inbox & email notifikasi milik admin (ops.enqueue_notification di sana): event notify.user.
create function ops.notify(p_user uuid, p_event text, p_payload jsonb, p_email boolean default true) returns void
language sql security definer set search_path = '' as $$
  select bus.emit('admin', 'notify.user', jsonb_build_object('user_id', p_user, 'event', p_event, 'payload', p_payload, 'email', p_email));
$$;

-- Identitas campaign untuk payload notifikasi: {campaign_id, campaign_title, org_id} (sama dengan admin market.campaign_ref).
create function market.campaign_ref(p_campaign uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'org_id', c.org_id)
                     from market.campaigns c where c.id = p_campaign), '{}');
end $$;
revoke execute on function ops.cfg(text, jsonb), ops.invoke_function(text, jsonb), ops.notify(uuid, text, jsonb, boolean),
  market.campaign_ref(uuid) from public;
