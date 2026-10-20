SET local check_function_bodies = off;

DROP FUNCTION "api"."bridge_pph21"(date, date);

CREATE OR REPLACE FUNCTION api.bridge_pph21 (
  p_from date,
  p_to   date
)
  RETURNS TABLE (
    user_id uuid,
    cash    numeric,
    noncash numeric,
    gross   numeric
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t0 timestamptz := p_from::timestamp at time zone 'Asia/Jakarta';
  t1 timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Jakarta';
begin
  return query
  select x.user_id, sum(x.cash), sum(x.noncash), sum(x.cash + x.noncash)
    from (select p.user_id, p.amount::numeric as cash, 0::numeric as noncash from finance.payouts p
           where p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1
          union all
          select f.user_id, 0, round(f.amount * rt.idr_value_per_unit, 2) from finance.fulfillments f
            join market.reward_types rt on rt.id = f.reward_type_id
           where f.status = 'delivered' and f.delivered_at >= t0 and f.delivered_at < t1) x
   group by x.user_id order by x.user_id;
end $function$;

REVOKE ALL ON FUNCTION "api"."bridge_pph21"(date, date) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_pph21"(date, date) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_pph21"(date, date) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_pph21"(date, date) TO "service_role";
