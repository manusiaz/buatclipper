SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bridge_get_payout (
  p_payout uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.payouts;
begin
  select * into p from finance.payouts x where x.id = p_payout;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id, 'amount', p.amount, 'fee', p.fee,
                            'net_amount', p.amount - p.fee, 'channel', p.channel, 'status', p.status, 'provider_ref', p.provider_ref);
end $function$;

CREATE OR REPLACE FUNCTION finance.retry_instant_payouts()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
  old int := 0;
begin
  for r in select p.id, p.created_at from finance.payouts p
            where p.channel = 'instant'
              and ((p.status in ('requested', 'processing') and p.provider_ref is null and p.created_at <= now() - interval '15 minutes')
                   or (p.status = 'processing' and p.provider_ref is not null and p.created_at <= now() - interval '1 hour'))
            order by p.created_at limit 200 loop
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', r.id));
    n := n + 1;
    if r.created_at <= now() - interval '1 hour' then
      old := old + 1;
    end if;
  end loop;
  if old > 0 then
    perform ops.raise_alert('payout.instant_stuck', 'warning', jsonb_build_object('count', old), interval '6 hours');
  end if;
  return n;
end $function$;
