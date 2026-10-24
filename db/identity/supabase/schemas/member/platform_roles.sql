-- E-27 role platform. Hanya role admin_*; akun tanpa baris = clipper/brand biasa. Sumber claim app_roles.
create table member.platform_roles (
  user_id uuid not null references auth.users (id) on delete cascade,
  role member.platform_role not null,
  granted_by uuid references auth.users (id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);
create index platform_roles_granted_by_idx on member.platform_roles (granted_by);

alter table member.platform_roles enable row level security;
create policy platform_roles_hook on member.platform_roles for select to supabase_auth_admin using (true);  -- policy:identity.auth-hook
create policy platform_roles_super_read on member.platform_roles for select to authenticated  -- policy:identity.admin-aal2
  using ((select member.is_admin('admin_super')));
grant select on member.platform_roles to authenticated, supabase_auth_admin;
