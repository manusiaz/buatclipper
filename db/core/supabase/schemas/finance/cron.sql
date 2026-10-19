-- job:earning-release (tiap jam, menit 7): Pending → Tersedia setelah lock + hold 7 hari tanpa fraud flag
-- (finance.release_earnings, kontrak di PRD Lampiran A).
-- job:reconcile-daily (18:00 UTC = 01:00 WIB): invarian ledger vs mutasi yang dicatat finance (finance.reconcile_ledger),
-- lalu bridge core memanggil bridge identity check_ids (alur 10) untuk ID lintas DB yatim; selisih → alert admin.
select cron.schedule('earning-release', '7 * * * *', $$select finance.release_earnings()$$);
select cron.schedule('reconcile-daily', '0 18 * * *',
                     $$select finance.reconcile_ledger(); select ops.invoke_function('bridge', '{"action":"reconcile_ids"}')$$);

-- job:referral-bonus (19:30 UTC = 02:30 WIB): bonus referral dari earning teman yang Tersedia hari itu (F-C16).
-- job:fulfillment-retry (5 menit): worker fulfill mengirim ulang webhook reward / memasang kode dari pool (F-B03).
select cron.schedule('referral-bonus', '30 19 * * *', $$select finance.accrue_referral_bonus()$$);
select cron.schedule('fulfillment-retry', '*/5 * * * *', $$select ops.invoke_function('fulfill')$$);
