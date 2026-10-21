-- E-36 langganan web push PWA (F-C14). Endpoint push = pengenal perangkat, jadi disimpan di identity, bukan core.
-- Push dikirim bridge identity (kunci VAPID = secret Edge Function identity) bersama email (alur 4).
create table member.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  -- webpush = PWA (VAPID, endpoint https + kunci p256dh/auth); expo = app native (token Expo push, tanpa kunci).
  kind text not null default 'webpush' check (kind in ('webpush', 'expo')),
  endpoint text not null,
  p256dh text,
  auth_secret text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  -- expo: id ticket kiriman terakhir; receipt-nya dicek sebelum kiriman berikutnya (DeviceNotRegistered → token dihapus).
  expo_ticket text,
  constraint push_subscriptions_endpoint_unique unique (endpoint),
  constraint push_subscriptions_kind_shape check (
    (kind = 'webpush' and endpoint ~ '^https://' and p256dh is not null and auth_secret is not null)
    or (kind = 'expo' and endpoint ~ '^Expo(nent)?PushToken\[[A-Za-z0-9_-]{10,200}\]$' and p256dh is null and auth_secret is null)
  )
);
create index push_subscriptions_user_idx on member.push_subscriptions (user_id);

alter table member.push_subscriptions enable row level security;
create policy push_subscriptions_own_read on member.push_subscriptions for select to authenticated  -- policy:identity.rls-self
  using (user_id = (select auth.uid()));
create policy push_subscriptions_own_delete on member.push_subscriptions for delete to authenticated  -- policy:identity.rls-self
  using (user_id = (select auth.uid()));
grant select (id, user_id, endpoint, created_at, last_used_at), delete on member.push_subscriptions to authenticated;

-- Simpan langganan perangkat ini untuk user sekarang. Perangkat yang sama berganti akun → endpoint dipindah ke akun baru.
create function api.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  sid uuid;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  insert into member.push_subscriptions (user_id, endpoint, p256dh, auth_secret)
  values (uid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh,
    auth_secret = excluded.auth_secret, created_at = now()
  returning id into sid;
  return sid;
end $$;
revoke execute on function api.save_push_subscription(text, text, text) from public;
grant execute on function api.save_push_subscription(text, text, text) to authenticated;

-- App native (Android/iOS): token Expo push perangkat ini. Sama dengan web push: perangkat berganti akun → token pindah.
create function api.save_expo_push_token(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  sid uuid;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  insert into member.push_subscriptions (user_id, kind, endpoint)
  values (uid, 'expo', p_token)
  on conflict (endpoint) do update set user_id = excluded.user_id, created_at = now()
  returning id into sid;
  return sid;
end $$;
revoke execute on function api.save_expo_push_token(text) from public;
grant execute on function api.save_expo_push_token(text) to authenticated;

create view api.push_subscriptions with (security_invoker = true) as
  select id, endpoint, created_at, last_used_at from member.push_subscriptions;
grant select, delete on api.push_subscriptions to authenticated;
