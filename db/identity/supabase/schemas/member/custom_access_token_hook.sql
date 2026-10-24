-- fn:custom_access_token_hook — dipanggil Supabase Auth (role supabase_auth_admin) sebelum JWT terbit.
-- URI: pg-functions://postgres/member/custom_access_token_hook. Tanpa security definer (saran docs Auth Hooks).
-- Claim tambahan: app_roles (E-27), kyc (E-05), consent_ok {clipper, brand} = consent versi terbaru E-28 vs E-31,
-- consent_ok.share_with_brand = izin berbagi data penerima ke brand belum dicabut (core menolak klaim reward ber-PII tanpanya).
create function member.has_current_consent(p_user uuid, p_kind member.consent_kind)
returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from member.consents c
    where c.user_id = p_user and c.kind = p_kind and c.revoked_at is null
      and c.version = (select max(v.version) from member.legal_versions v
                       where v.kind = p_kind and v.published_at <= now()));
$$;

create function member.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql stable set search_path = '' as $$
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
end $$;

revoke execute on function member.has_current_consent(uuid, member.consent_kind) from public, anon, authenticated;
revoke execute on function member.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant execute on function member.has_current_consent(uuid, member.consent_kind) to supabase_auth_admin;
grant execute on function member.custom_access_token_hook(jsonb) to supabase_auth_admin;
