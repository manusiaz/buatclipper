-- Nama project ini di bus antar database (target di bus.outbox milik project lain menunjuk nama ini).
create function bus.me() returns text
language sql immutable set search_path = '' as $$ select 'admin' $$;

select cron.schedule('bus-relay', '1 seconds', $$select bus.relay()$$);
-- job:bus-reconcile — penghapusan rekonsiliasi restore, bertahap (bus.reconcile_apply)
select cron.schedule('bus-reconcile', '30 seconds', $$select bus.reconcile_apply()$$);
-- job:bus-prune — retensi outbox terkirim (bus.prune)
select cron.schedule('bus-prune', '17 3 * * *', $$select bus.prune()$$);
