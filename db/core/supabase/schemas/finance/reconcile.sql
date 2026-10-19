-- job:reconcile-daily bagian ledger (F-A08): invarian ledger vs mutasi yang dicatat finance. Selisih → alert reconcile.ledger.
--   pool_cache              reward_pools.allocated ≠ jurnal pool (accrual/reversal/release)
--   negative_wallet         saldo Pending/Tersedia clipper < 0
--   invoice_unposted        invoice lunas tanpa kaki sumber (bank_clearing/org_credit Rupiah) = −total di jurnal invoice_payment
--   journal_without_invoice jurnal invoice_payment tanpa invoice lunas
-- Mutasi rekening bank sungguhan (di luar sistem) dicocokkan finance dengan payment_ref/bank_ref.
create function finance.reconcile_ledger() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  idr uuid := finance.idr();
  issues jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'pool_cache', (select jsonb_agg(rp.id) from finance.reward_pools rp
                    where rp.allocated <> coalesce((select -sum(e.amount) from finance.ledger_entries e
                                                      join finance.ledger_accounts a on a.id = e.account_id
                                                     where a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                                       and e.ref_type in ('accrual', 'reversal', 'release')), 0)),
    'negative_wallet', (select jsonb_agg(a.id) from finance.ledger_accounts a
                         where a.owner_type = 'user_wallet'
                           and (select coalesce(sum(e.amount), 0) from finance.ledger_entries e
                                 where e.account_id = a.id and e.state in ('pending', 'available')) < 0),
    'invoice_unposted', (select jsonb_agg(i.id) from finance.invoices i
                          where i.status = 'paid'
                            and not exists (select 1 from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                             where e.ref_type = 'invoice_payment' and e.ref_id = i.id::text and e.amount = -i.total
                                               and a.owner_type in ('bank_clearing', 'org_credit') and a.reward_type_id = idr)),
    'journal_without_invoice', (select jsonb_agg(distinct e.ref_id) from finance.ledger_entries e
                                 where e.ref_type = 'invoice_payment'
                                   and not exists (select 1 from finance.invoices i where i.id::text = e.ref_id and i.status = 'paid'))))
    into issues;
  if issues <> '{}' then
    perform ops.raise_alert('reconcile.ledger', 'critical', issues);
  end if;
  return issues;
end $$;
revoke execute on function finance.reconcile_ledger() from public;
