-- E-04 akun sosmed terhubung lewat OAuth (F-C02). Satu akun sosmed = satu clipper, permanen (UNIQUE platform + external_id,
-- termasuk yang sudah diputus) supaya akun tidak bisa dijual-pindah. Token di Vault creator; tabel hanya memegang token_ref.
-- Pemilik: project creator. Replika tanpa token_ref ke admin (claim_check, fraud, tampilan admin).
create table tracking.social_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references market.profiles (id),
  platform market.platform not null,
  external_id text not null,
  handle text not null,
  token_ref uuid,
  status text not null default 'verified' check (status in ('verified', 'token_expired', 'revoked', 'disconnected')),
  followers integer check (followers >= 0),
  platform_created_at timestamptz,
  verified_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint social_accounts_one_owner unique (platform, external_id),
  constraint social_accounts_key unique (id, user_id, platform)
);
create index social_accounts_user_idx on tracking.social_accounts (user_id, platform);
create trigger social_accounts_replicate after insert or update or delete on tracking.social_accounts for each row
  execute function bus.replicate('admin:user_id,platform,external_id,handle,status,followers,platform_created_at,verified_at,created_at');

-- Maks akun aktif per platform per clipper (config public.market.max_accounts_per_platform, default 3).
create function tracking.check_account_limit() returns trigger
language plpgsql set search_path = '' as $$
declare
  n int;
  max_n int := coalesce((select (s.value #>> '{}')::int from ops.settings s
                         where s.key = 'public.market.max_accounts_per_platform'), 3);
begin
  -- Hanya yang menambah akun aktif yang dibatasi (insert, disconnected → aktif, pindah user/platform). Perubahan status di antara
  -- verified/token_expired/revoked tidak menambah akun, jadi tetap jalan walau batas config diturunkan (R36-1).
  if tg_op = 'UPDATE' and old.status <> 'disconnected' and old.user_id = new.user_id and old.platform = new.platform then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text || ':' || new.platform::text, 0));
  select count(*) into n from tracking.social_accounts a
   where a.user_id = new.user_id and a.platform = new.platform and a.status <> 'disconnected' and a.id <> new.id;
  if n >= max_n then
    raise exception 'maksimal % akun % per clipper', max_n, new.platform using errcode = '23514';
  end if;
  return new;
end $$;
create trigger social_accounts_limit before insert or update of user_id, platform, status on tracking.social_accounts
  for each row when (new.status <> 'disconnected') execute function tracking.check_account_limit();

alter table tracking.social_accounts enable row level security;
create policy social_accounts_iss on tracking.social_accounts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy social_accounts_own_read on tracking.social_accounts for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy social_accounts_admin_read on tracking.social_accounts for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_moderator', 'admin_support')));
grant select (id, user_id, platform, external_id, handle, status, followers, platform_created_at, verified_at, created_at)
  on tracking.social_accounts to authenticated;
