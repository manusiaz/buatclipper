-- Nama project ini di bus antar database (target di bus.outbox milik project lain menunjuk nama ini).
create function bus.me() returns text
language sql immutable set search_path = '' as $$ select 'admin' $$;

select cron.schedule('bus-relay', '5 seconds', $$select bus.relay()$$);
