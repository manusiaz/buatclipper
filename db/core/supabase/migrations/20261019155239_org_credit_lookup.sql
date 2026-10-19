SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.org_credit (
  p_org uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  acc uuid;
begin
  perform market.session_uid();
  if not (ops.is_org_member(p_org, 'brand_owner', 'brand_finance') or ops.has_admin('admin_finance')) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_finance', '42501');
  end if;
  select a.id into acc from finance.ledger_accounts a
   where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr();
  return jsonb_build_object(
    'balance', trim_scale(coalesce(finance.balance(acc), 0)),
    'available', trim_scale(finance.org_credit_available(p_org)),
    'history', coalesce((select jsonb_agg(jsonb_build_object('amount', trim_scale(e.amount), 'ref_type', e.ref_type, 'ref_id', e.ref_id,
                                                             'created_at', e.created_at) order by e.created_at desc)
                           from (select * from finance.ledger_entries x where x.account_id = acc
                                  order by x.created_at desc limit 50) e), '[]'::jsonb),
    'leftovers', coalesce((select jsonb_agg(jsonb_build_object('campaign_id', c.id, 'title', c.title, 'amount', trim_scale(l.amount)))
                             from market.campaigns c
                             cross join lateral (select sum(finance.balance(a.id)) as amount
                                                   from finance.reward_pools rp
                                                   join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                                  where rp.campaign_id = c.id and rp.reward_type_id = finance.idr()) l
                            where c.org_id = p_org and c.status in ('settled', 'cancelled') and l.amount > 0), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION finance.org_credit_available (
  p_org uuid
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                     where a.owner_type = 'org_credit' and a.owner_id = p_org and a.reward_type_id = finance.idr()), 0)
         - coalesce((select sum(r.amount) from finance.org_refunds r where r.org_id = p_org and r.status in ('requested', 'approved')), 0);
$function$;
