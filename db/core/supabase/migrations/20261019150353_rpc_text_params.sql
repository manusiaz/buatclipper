SET local check_function_bodies = off;

DROP FUNCTION "api"."create_org_invite"(uuid, market.org_role);

DROP FUNCTION "api"."worker_upsert_social_account"(uuid, market.platform, text, text, integer, timestamp WITH time zone, text);

CREATE OR REPLACE FUNCTION api.create_org_invite (
  p_org  uuid,
  p_role text
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r market.org_role := p_role::market.org_role;
  uid uuid := market.session_uid();
  tok text;
begin
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if r is null then
    perform market.fail('invalid:role', 'role wajib');
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.org_invites (org_id, role, token_hash, expires_at, created_by)
  values (p_org, r, sha256(convert_to(tok, 'UTF8')), now() + interval '7 days', uid);
  return tok;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_upsert_social_account (
  p_user                uuid,
  p_platform            text,
  p_external_id         text,
  p_handle              text,
  p_followers           integer,
  p_platform_created_at timestamp with time zone,
  p_token               text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pf market.platform := p_platform::market.platform;
  a tracking.social_accounts;
  aid uuid;
begin
  if not exists (select 1 from market.profiles pr where pr.id = p_user and pr.status = 'active') then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.platform = pf and x.external_id = p_external_id for update;
  if found then
    if a.user_id <> p_user then
      raise exception 'social_taken' using errcode = 'P0001';
    end if;
    update tracking.social_accounts
       set handle = p_handle, followers = coalesce(p_followers, followers),
           platform_created_at = coalesce(p_platform_created_at, platform_created_at), status = 'verified', verified_at = now()
     where id = a.id;
    aid := a.id;
  else
    begin
      insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
      values (p_user, pf, p_external_id, p_handle, p_followers, p_platform_created_at) returning id into aid;
    exception when unique_violation then
      raise exception 'social_taken' using errcode = 'P0001';
    end;
  end if;
  if p_token is not null then
    perform api.store_social_token(aid, p_token);
  end if;
  update tracking.submissions set next_poll_at = now()
   where social_account_id = aid and status in ('tracking', 'flagged') and next_poll_at is null;
  return aid;
end $function$;

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, text, text, text, integer, timestamp WITH time zone, text) TO "service_role";
