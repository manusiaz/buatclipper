SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.ensure_member_profile (
  p_user         uuid,
  p_username     text DEFAULT NULL::text,
  p_display_name text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform bus.emit('creator', 'profile.ensure', jsonb_build_object('user_id', p_user, 'username', p_username, 'display_name', p_display_name));
end $function$;
