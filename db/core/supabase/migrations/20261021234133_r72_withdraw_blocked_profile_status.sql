SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION finance.withdraw_blocked (
  p_user uuid
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select not exists (select 1 from market.profiles pr where pr.id = p_user
                      and (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now())))
      or exists (select 1 from trust.fraud_flags f where f.target_type = 'profile' and f.target_id = p_user and f.status in ('open', 'held'));
$function$;
