SET local check_function_bodies = off;

SELECT cron.unschedule('bus-relay');

SELECT cron.schedule_in_database('bus-relay', '1 seconds', 'select bus.relay()', 'postgres', NULL, true);
