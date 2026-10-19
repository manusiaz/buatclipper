-- E-36 langganan web push PWA (F-C14). Endpoint push = pengenal perangkat, jadi disimpan di identity, bukan core.
-- Push dikirim bridge identity (kunci VAPID = secret Edge Function identity) bersama email (alur 4).
create table member.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null check (endpoint ~ '^https://'),
  p256dh text not null,
  auth_secret text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  constraint push_subscriptions_endpoint_unique unique (endpoint)
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

create view api.push_subscriptions with (security_invoker = true) as
  select id, endpoint, created_at, last_used_at from member.push_subscriptions;
grant select, delete on api.push_subscriptions to authenticated;
