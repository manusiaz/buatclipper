-- job:track-due (15 menit) mengisi queue track; worker track-worker dipicu tiap 5 menit dan mengambil batch kecil
-- (batas CPU Edge Function 2 detik/request). job:token-refresh tiap 6 jam (token TikTok 24 jam).
select cron.schedule('track-due', '*/15 * * * *', $$select tracking.enqueue_due_submissions()$$);
select cron.schedule('track-worker', '*/5 * * * *', $$select ops.invoke_function('track-worker')$$);
select cron.schedule('token-refresh', '0 */6 * * *', $$select ops.invoke_function('refresh-tokens')$$);
