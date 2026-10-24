-- Nama project ini di bus antar database (target di bus.outbox milik project lain menunjuk nama ini).
create function bus.me() returns text
language sql immutable set search_path = '' as $$ select 'brand' $$;

select cron.schedule('bus-relay', '1 seconds', $$select bus.relay()$$);
-- job:bus-prune — retensi outbox/inbox (bus.prune)
select cron.schedule('bus-prune', '17 3 * * *', $$select bus.prune()$$);
-- job:bus-ping — tanda hidup + antrean macet ke admin (pemantauan bus, ops.watch_bus di admin).
select cron.schedule('bus-ping', '*/5 * * * *', $$select bus.ping()$$);
