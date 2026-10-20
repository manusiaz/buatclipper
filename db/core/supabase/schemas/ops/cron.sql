-- Queue (Supabase Queues/pgmq) dan job ops. Jadwal pg_cron dalam UTC (WIB = UTC+7).
-- Catatan: job & queue adalah konfigurasi extension, bukan DDL biasa. pg-delta melacak job pg_cron bernama; kalau diff tidak
-- menangkap queue, jalankan file ini sebagai migration manual (dicek di Fase 0).
select pgmq.create('tracking');
select pgmq.create('email');

-- job:notify-drain — tiap menit memicu worker notify: kuras antrean email → bridge identity (alur 4).
select cron.schedule('notify-drain', '* * * * *', $$select ops.invoke_function('notify')$$);

-- job:broadcast-dispatch (tiap menit): kirim broadcast yang sudah waktunya (F-A12; ops.dispatch_broadcasts, kontrak).
select cron.schedule('broadcast-dispatch', '* * * * *', $$select ops.dispatch_broadcasts()$$);

-- job:alert-notify (tiap 15 menit): ulangi email admin untuk alert yang belum terkirim (F-X01; ops.notify_alerts).
select cron.schedule('alert-notify', '*/15 * * * *', $$select ops.notify_alerts()$$);
