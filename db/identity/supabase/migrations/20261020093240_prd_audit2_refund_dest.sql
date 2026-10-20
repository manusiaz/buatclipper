SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.svc_user_payout_methods (
  p_user uuid
)
  RETURNS TABLE (
    id              uuid,
    user_id         uuid,
    kind            text,
    bank_code       text,
    account_no_enc  bytea,
    account_last4   text,
    enc_key_version smallint,
    account_name    text,
    disabled_at     timestamp with time zone,
    blocked         boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select pm.id, pm.user_id, pm.kind, pm.bank_code, pm.account_no_enc, pm.account_last4, pm.enc_key_version,
         pm.account_name, pm.disabled_at, pm.blocked
  from member.payout_methods pm
  where pm.user_id = p_user and pm.kind = 'bank' and pm.disabled_at is null and not pm.blocked
  order by pm.created_at desc;
$function$;

REVOKE ALL ON FUNCTION "api"."svc_user_payout_methods"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_user_payout_methods"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_user_payout_methods"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_user_payout_methods"(uuid) TO "service_role";
