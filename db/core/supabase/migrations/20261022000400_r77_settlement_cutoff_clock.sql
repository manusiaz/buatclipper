SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION finance.start_settlement (
  p_pool uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  -- clock_timestamp, bukan now(): snapshot pemicu (diambil lebih dulu di transaksi yang sama) tercatat sebelum cut-off, jadi
  -- submisinya ikut dapat jatah dari poll berikutnya (R77).
  insert into finance.pool_settlements (pool_id, cutoff_at) values (p_pool, clock_timestamp()) on conflict (pool_id) do nothing;
  if found then
    update tracking.submissions t set next_poll_at = now()
     where t.id in (select o.id from tracking.submissions o join finance.reward_pools rp on rp.campaign_id = o.campaign_id
                    where rp.id = p_pool and o.status = 'tracking' and o.next_poll_at > now()
                    for update of o skip locked);
  end if;
end $function$;
