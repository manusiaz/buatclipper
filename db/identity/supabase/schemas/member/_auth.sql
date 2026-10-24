-- policy:identity.admin-aal2 — role admin dibaca dari E-27 (bukan claim) + wajib aal2.
-- security definer supaya policy tidak rekursif lewat RLS platform_roles. plpgsql: badan fungsi tidak di-resolve saat
-- dibuat, jadi file ini tidak bergantung pada urutan file tabel (pg-delta mengurutkan per file).
create function member.is_admin(variadic roles member.platform_role[] default '{}')
returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (
       select 1 from member.platform_roles pr
       where pr.user_id = (select auth.uid())
         and (pr.role = 'admin_super' or cardinality(roles) = 0 or pr.role = any (roles)));
end $$;
revoke execute on function member.is_admin(member.platform_role[]) from public;
grant execute on function member.is_admin(member.platform_role[]) to authenticated;
