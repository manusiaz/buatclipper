-- F-A01 overview admin (admin apa pun, aal2). Bulan = bulan kalender WIB. Revenue = mutasi akun platform_revenue Rupiah (fee
-- invoice, layanan, biaya instant & transfer refund, dikurangi bonus referral). Kesehatan tracking: submisi terlambat > 2 jam
-- dari jadwal poll dan umur snapshot terakhir.
create function api.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
  rev uuid := (select a.id from finance.ledger_accounts a join market.reward_types rt on rt.id = a.reward_type_id
               where a.owner_type = 'platform_revenue' and rt.code = 'IDR' and rt.owner_org_id is null);
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'gmv', (select jsonb_build_object('month', coalesce(sum(i.total) filter (where i.paid_at >= month_start), 0),
                                      'all_time', coalesce(sum(i.total), 0))
              from finance.invoices i where i.status = 'paid'),
    'revenue', (select jsonb_build_object('month', coalesce(sum(e.amount) filter (where e.created_at >= month_start), 0),
                                          'all_time', coalesce(sum(e.amount), 0))
                  from finance.ledger_entries e where e.account_id = rev),
    'active_campaigns', (select count(*) from market.campaigns c where c.status in ('live', 'paused', 'tracking')),
    'payout_pending', (select jsonb_build_object('count', count(*), 'sum', coalesce(sum(p.amount), 0))
                         from finance.payouts p where p.status in ('requested', 'on_hold', 'processing')),
    'fraud_queue', (select count(*) from trust.fraud_flags f where f.status in ('open', 'held')),
    'tracking', jsonb_build_object(
      'overdue', (select count(*) from tracking.submissions s
                   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours'),
      'last_snapshot_age_seconds', (select floor(extract(epoch from now() - max(v.taken_at))) from tracking.view_snapshots v)),
    'open_alerts', (select count(*) from ops.alerts a where a.resolved_at is null));
end $$;

revoke execute on function api.admin_overview() from public;
grant execute on function api.admin_overview() to authenticated;
