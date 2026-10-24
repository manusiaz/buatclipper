-- job:fraud-device-scan (tiap jam, menit 30): bridge identity membaca grup banyak akun per IP + user agent lewat
-- api.shared_device_groups, lalu meneruskan ke bridge core raise_fraud_flag (FR-05, alur 6).
-- job:push-receipts (tiap 30 menit): bridge membaca receipt ticket Expo ≥ 15 menit (api.svc_due_push_tickets), token
-- DeviceNotRegistered dihapus (api.svc_resolve_push_tickets).
-- URL & secret key identity dibaca dari Vault identity.
create function member.invoke_function(p_name text, p_body jsonb default '{}')
returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'identity_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'identity_secret_key')));
$$;
revoke execute on function member.invoke_function(text, jsonb) from public;

select cron.schedule('fraud-device-scan', '30 * * * *', $$select member.invoke_function('bridge', '{"action":"fraud_device_scan"}')$$);
select cron.schedule('push-receipts', '*/30 * * * *', $$select member.invoke_function('bridge', '{"action":"push_receipts"}')$$);
