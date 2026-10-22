-- Helper akses brand. plpgsql: badan fungsi tidak di-resolve saat dibuat, jadi file ini tidak bergantung pada file tabel.
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
