-- E-28 consent UU PDP. Tiap persetujuan = satu baris per versi; dicabut = revoked_at. Ditulis hanya lewat api.record_consent.
create table member.consents (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind member.consent_kind not null,
  version text not null check (version ~ '^\d{4}-\d{2}-\d{2}$'),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint consents_revoked_after_granted check (revoked_at is null or revoked_at >= granted_at),
  constraint consents_one_per_version unique (user_id, kind, version)
);
create index consents_user_kind_idx on member.consents (user_id, kind, granted_at desc);

alter table member.consents enable row level security;
create policy consents_own_read on member.consents for select to authenticated using (user_id = (select auth.uid()));  -- policy:identity.rls-self
create policy consents_hook on member.consents for select to supabase_auth_admin using (true);  -- policy:identity.auth-hook
grant select on member.consents to authenticated, supabase_auth_admin;
