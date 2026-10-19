-- Helper akses core. plpgsql: badan fungsi tidak di-resolve saat dibuat, jadi file ini tidak bergantung pada file tabel.
-- Semua security definer: dipanggil policy atas nama anon/authenticated, yang sengaja tidak punya USAGE ke schema internal.

-- policy:core.iss-identity — JWT harus terbitan identity (issuer per environment di E-25 auth.identity_issuer).
create function ops.iss_ok() returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select auth.jwt() ->> 'iss')
                  = (select s.value #>> '{}' from ops.settings s where s.key = 'auth.identity_issuer'), false);
end $$;

-- policy:core.admin-aal2 — claim app_roles (hook identity) + aal2. Tanpa argumen = role admin_* apa pun.
create function ops.has_admin(variadic roles text[] default '{}') returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return ops.iss_ok()
     and coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (select 1 from jsonb_array_elements_text(coalesce((select auth.jwt() -> 'app_roles'), '[]'::jsonb)) r(role)
                 where r.role = 'admin_super' or (cardinality(roles) = 0 and r.role like 'admin\_%') or r.role = any (roles));
end $$;

-- policy:core.org-role — role user di satu org (E-03). Kalau bukan anggota langsung, role dari org agency yang ditautkan ke org
-- itu (E-38, F-B12). security definer supaya policy org_members tidak rekursif.
create function ops.org_role(p_org uuid) returns market.org_role
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce(
    (select m.role from market.org_members m where m.org_id = p_org and m.user_id = (select auth.uid())),
    (select m.role from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
      where l.client_org_id = p_org and l.revoked_at is null and m.user_id = (select auth.uid())
      order by array_position(enum_range(null::market.org_role), m.role) limit 1));
end $$;

-- policy:core.rls-org — anggota org (opsional dibatasi role).
create function ops.is_org_member(p_org uuid, variadic roles market.org_role[] default '{}') returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  r text := ops.org_role(p_org)::text;
begin
  return r is not null and (cardinality(roles) = 0 or r = any (roles::text[]));
end $$;

revoke execute on function ops.iss_ok(), ops.has_admin(text[]), ops.org_role(uuid), ops.is_org_member(uuid, market.org_role[]) from public;
grant execute on function ops.iss_ok(), ops.has_admin(text[]), ops.org_role(uuid), ops.is_org_member(uuid, market.org_role[]) to authenticated;
