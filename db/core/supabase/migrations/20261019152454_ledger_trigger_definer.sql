SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION finance.check_txn_balanced()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from finance.ledger_entries e where e.txn_id = new.txn_id
             group by e.reward_type_id having sum(e.amount) <> 0) then
    raise exception 'transaksi % tidak seimbang (jumlah per reward type harus 0)', new.txn_id using errcode = '23514';
  end if;
  return null;
end $function$;
