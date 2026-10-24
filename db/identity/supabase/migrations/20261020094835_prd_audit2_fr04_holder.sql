SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.svc_hash_holder (
  p_nik_hash     bytea,
  p_bank_code    text,
  p_account_hash bytea
)
  RETURNS TABLE (
    user_id   uuid,
    tombstone boolean
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select k.user_id, k.user_id is null from member.kyc_records k where p_nik_hash is not null and k.nik_hash = p_nik_hash
  union all
  select pm.user_id, pm.user_id is null from member.payout_methods pm
   where p_account_hash is not null and pm.bank_code = p_bank_code and pm.account_no_hash = p_account_hash
  limit 1;
$function$;

REVOKE ALL ON FUNCTION "api"."svc_hash_holder"(bytea, text, bytea) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."svc_hash_holder"(bytea, text, bytea) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_hash_holder"(bytea, text, bytea) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."svc_hash_holder"(bytea, text, bytea) TO "service_role";
