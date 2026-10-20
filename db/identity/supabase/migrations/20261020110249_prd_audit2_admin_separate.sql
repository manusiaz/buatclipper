SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.admin_set_role (
  p_user_id uuid,
  p_role    text,
  p_grant   boolean
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r member.platform_role := p_role::member.platform_role;
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  if p_user_id = (select auth.uid()) and r = 'admin_super' and not p_grant then
    raise exception 'tidak bisa mencabut admin_super milik sendiri' using errcode = '22023';
  end if;
  -- §4: akun admin dibuat terpisah dari akun clipper/brand → akun yang pernah setuju ToS clipper/brand tidak bisa jadi admin
  -- (kecuali sudah admin: menambah role kedua).
  if p_grant and not exists (select 1 from member.platform_roles x where x.user_id = p_user_id)
     and exists (select 1 from member.consents c where c.user_id = p_user_id and c.kind in ('tos_clipper', 'tos_brand')) then
    raise exception 'admin_account_must_be_separate' using errcode = '22023';
  end if;
  if p_grant then
    insert into member.platform_roles (user_id, role, granted_by)
    values (p_user_id, r, (select auth.uid()))
    on conflict (user_id, role) do nothing;
  else
    delete from member.platform_roles where user_id = p_user_id and role = r;
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), case when p_grant then 'role.grant' else 'role.revoke' end, 'user:' || p_user_id,
          jsonb_build_object('role', r));
end $function$;
