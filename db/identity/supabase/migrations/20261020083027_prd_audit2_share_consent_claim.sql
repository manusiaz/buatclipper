SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION member.custom_access_token_hook (
  event jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (event ->> 'user_id')::uuid;
  roles jsonb;
  kyc text;
  privacy_ok boolean := member.has_current_consent(uid, 'privacy');
begin
  select coalesce(jsonb_agg(pr.role order by pr.role), '[]'::jsonb) into roles
    from member.platform_roles pr where pr.user_id = uid;
  select k.status::text into kyc from member.kyc_records k where k.user_id = uid;
  return jsonb_set(event, '{claims}', (event -> 'claims') || jsonb_build_object(
    'app_roles', roles,
    'kyc', coalesce(kyc, 'none'),
    'consent_ok', jsonb_build_object(
      'clipper', privacy_ok and member.has_current_consent(uid, 'tos_clipper')
                 and exists (select 1 from member.consents c
                             where c.user_id = uid and c.kind = 'age_18_plus' and c.revoked_at is null),
      'brand', privacy_ok and member.has_current_consent(uid, 'tos_brand'),
      'share_with_brand', exists (select 1 from member.consents c
                                   where c.user_id = uid and c.kind = 'share_with_brand' and c.revoked_at is null))));
end $function$;
