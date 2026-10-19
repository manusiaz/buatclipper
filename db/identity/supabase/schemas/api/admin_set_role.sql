-- admin_super (aal2) memberi/mencabut role platform E-27. Berlaku di JWT berikutnya (≤ 10 menit).
create function api.admin_set_role(p_user_id uuid, p_role member.platform_role, p_grant boolean)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and p_role = 'admin_super' and not p_grant then
    raise exception 'tidak bisa mencabut admin_super milik sendiri' using errcode = '22023';
  end if;
  if p_grant then
    insert into member.platform_roles (user_id, role, granted_by)
    values (p_user_id, p_role, (select auth.uid()))
    on conflict (user_id, role) do nothing;
  else
    delete from member.platform_roles where user_id = p_user_id and role = p_role;
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), case when p_grant then 'role.grant' else 'role.revoke' end, 'user:' || p_user_id,
          jsonb_build_object('role', p_role));
end $$;
revoke execute on function api.admin_set_role(uuid, member.platform_role, boolean) from public;
grant execute on function api.admin_set_role(uuid, member.platform_role, boolean) to authenticated;
