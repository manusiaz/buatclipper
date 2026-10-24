-- job:claim-expiry (10 menit): pengingat + claim kedaluwarsa. job:lifecycle (5 menit): transisi S-01, lock submisi di akhir
-- view window, settlement mode, auto-approve review brand 72 jam (market.run_lifecycle, kontrak di PRD Lampiran A).
select cron.schedule('claim-expiry', '*/10 * * * *', $$select market.run_claim_expiry()$$);
select cron.schedule('lifecycle', '*/5 * * * *', $$select market.run_lifecycle()$$);

-- job:leaderboard-refresh (tiap jam, menit 17) dan job:budget-alerts (30 menit: proyeksi pemakaian budget < 50% → alert brand,
-- notifikasi 50/80/100% terpakai; market.run_budget_alerts, kontrak di Lampiran A).
select cron.schedule('leaderboard-refresh', '17 * * * *', $$select market.refresh_leaderboard()$$);
select cron.schedule('budget-alerts', '*/30 * * * *', $$select market.run_budget_alerts()$$);
