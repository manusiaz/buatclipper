SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.manage_team (
  p_org    uuid,
  p_action text,
  p_target uuid,
  p_role   text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  m market.org_members;
  r market.org_role;
begin
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  perform 1 from market.organizations where id = p_org for update;
  if p_action = 'revoke_invite' then
    delete from market.org_invites where id = p_target and org_id = p_org and accepted_at is null;
    if not found then
      perform market.fail('not_found:invite', null, 'P0002');
    end if;
  elsif p_action in ('set_role', 'remove') then
    select * into m from market.org_members where org_id = p_org and user_id = p_target;
    if m.user_id is null then
      perform market.fail('not_found:member', null, 'P0002');
    end if;
    if p_action = 'set_role' then
      r := p_role::market.org_role;
      if r is null then
        perform market.fail('invalid:role', 'role wajib');
      end if;
    end if;
    if m.role = 'brand_owner' and r is distinct from 'brand_owner'
       and not exists (select 1 from market.org_members o where o.org_id = p_org and o.role = 'brand_owner' and o.user_id <> m.user_id) then
      perform market.fail('last_owner', 'org harus punya minimal satu brand_owner');
    end if;
    if p_action = 'remove' then
      delete from market.org_members where org_id = p_org and user_id = m.user_id;
    else
      update market.org_members set role = r where org_id = p_org and user_id = m.user_id;
    end if;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.team.' || p_action, 'org:' || p_org,
          case when m.user_id is not null then jsonb_build_object('user_id', m.user_id, 'role', m.role) else jsonb_build_object('invite_id', p_target) end,
          case when p_action = 'set_role' then jsonb_build_object('role', r) end);
end $function$;

REVOKE ALL ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."manage_team"(uuid, text, uuid, text) TO "postgres";
