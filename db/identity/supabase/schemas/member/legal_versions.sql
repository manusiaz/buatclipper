-- E-31 versi ToS/privasi yang terbit. record_consent hanya menerima versi terbaru; hook mengisi claim consent_ok dari sini.
create table member.legal_versions (
  kind member.consent_kind not null check (kind in ('tos_clipper', 'tos_brand', 'privacy')),
  version text not null check (version ~ '^\d{4}-\d{2}-\d{2}$'),
  published_at timestamptz not null default now(),
  url text not null check (url ~ '^https://'),
  primary key (kind, version)
);

alter table member.legal_versions enable row level security;
create policy legal_versions_read on member.legal_versions for select to anon, authenticated using (true);  -- policy:identity.public-read
create policy legal_versions_hook on member.legal_versions for select to supabase_auth_admin using (true);  -- policy:identity.auth-hook
grant select on member.legal_versions to anon, authenticated, supabase_auth_admin;
