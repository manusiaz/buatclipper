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
  perform 1 from market.organizations where id = p_org for update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
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
    -- link undangan yang dibuat owner itu tidak boleh jadi jalan kembali setelah dikeluarkan/diturunkan
    if m.role = 'brand_owner' and r is distinct from 'brand_owner' then
      delete from market.org_invites where org_id = p_org and created_by = m.user_id and accepted_at is null;
    end if;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.team.' || p_action, 'org:' || p_org,
          case when m.user_id is not null then jsonb_build_object('user_id', m.user_id, 'role', m.role) else jsonb_build_object('invite_id', p_target) end,
          case when p_action = 'set_role' then jsonb_build_object('role', r) end);
end $function$;

CREATE OR REPLACE FUNCTION api.update_org (
  p_org        uuid,
  p_name       text,
  p_legal_name text DEFAULT NULL::text,
  p_npwp       text DEFAULT NULL::text,
  p_address    text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  o market.organizations;
  v_npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
  legal_changed boolean;
begin
  select * into o from market.organizations where id = p_org for update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if o.org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if v_npwp is null or v_npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
    if nullif(btrim(p_address), '') is null then
      perform market.fail('invalid:address', 'badan usaha wajib alamat');
    end if;
  elsif coalesce(p_legal_name, p_npwp, p_address) is not null then
    perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
  end if;
  legal_changed := o.org_type = 'badan' and (o.legal_name is distinct from btrim(p_legal_name) or o.npwp is distinct from v_npwp
                                             or o.address is distinct from btrim(p_address));
  update market.organizations
     set name = btrim(p_name), legal_name = nullif(btrim(p_legal_name), ''), npwp = v_npwp, address = nullif(btrim(p_address), ''),
         updated_at = now(),
         status = case when legal_changed and status = 'verified' then 'pending_verification' else status end,
         verified_at = case when legal_changed and status = 'verified' then null else verified_at end,
         verified_by = case when legal_changed and status = 'verified' then null else verified_by end
   where id = o.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.update', 'org:' || o.id,
          jsonb_build_object('name', o.name, 'legal_name', o.legal_name, 'npwp', o.npwp, 'address', o.address, 'status', o.status),
          jsonb_build_object('name', btrim(p_name), 'legal_name', nullif(btrim(p_legal_name), ''), 'npwp', v_npwp,
                             'address', nullif(btrim(p_address), ''), 'reverify', legal_changed));
end $function$;

CREATE OR REPLACE FUNCTION market.is_direct_member (
  p_org    uuid,
  p_user   uuid,
  VARIADIC p_roles market.org_role[] DEFAULT '{}'::market.org_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform 1 from market.org_members m where m.org_id = p_org and m.user_id = p_user
                                         and (cardinality(p_roles) = 0 or m.role = any (p_roles))
     for share;
  return found;
end $function$;
