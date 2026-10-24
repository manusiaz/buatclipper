SET local check_function_bodies = off;

SELECT cron.unschedule('bus-prune');

CREATE OR REPLACE FUNCTION bus.ping()
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t0 timestamptz := clock_timestamp();  -- sebelum membaca pg_stat_activity: transaksi yang mulai sesudahnya tidak diklaim
  h record;
begin
  select a.pid, a.xact_start, a.state into h from pg_stat_activity a
   where a.datname = current_database() and a.backend_type = 'client backend' and a.xact_start is not null
     and a.pid <> pg_backend_pid()
   order by a.xact_start limit 1;
  return bus.emit('admin', 'bus.ping', jsonb_build_object('source', bus.me(), 'at', least(t0, h.xact_start),
    'stuck', coalesce((select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts))
                         from bus.stuck() s), '[]')
             || case when h.xact_start < t0 - interval '5 minutes'
                     then jsonb_build_array(jsonb_build_object('target', 'transaksi', 'since', h.xact_start, 'pid', h.pid, 'state', h.state))
                     else '[]' end));
end $function$;

CREATE OR REPLACE FUNCTION bus.scrub_closed()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  with u as (select p.id::text as id from market.profiles p where p.status = 'closed'),
       s as (select s.id::text as id from tracking.submissions s join market.profiles p on p.id = s.user_id where p.status = 'closed')
  delete from bus.outbox o
   where o.sent_at is not null
     and (o.payload -> 'key' ->> 'id' in (select id from u) or o.payload -> 'row' ->> 'user_id' in (select id from u)
          or o.payload ->> 'user_id' in (select id from u) or o.payload -> 'row' ->> 'submission_id' in (select id from s));
$function$;

CREATE OR REPLACE FUNCTION bus_in.profile_anonymize (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
begin
  -- upsert nisan closed: profil yang belum ada (hapus akun sebelum onboarding) tidak bisa dibuat ulang ensure_profile memakai JWT
  -- yang belum kedaluwarsa (ensure_profile hanya memperbarui profil active)
  insert into market.profiles (id, username, display_name, status)
  values (v_user, 'deleted_' || substr(md5(v_user::text), 1, 22), 'Akun dihapus', 'closed')
  on conflict (id) do update set username = excluded.username, display_name = excluded.display_name, avatar_path = null,
                                 status = 'closed';
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = v_user);
  delete from tracking.social_accounts a
   where a.user_id = v_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = v_user;
end $function$;

REVOKE ALL ON FUNCTION "bus"."scrub_closed"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."scrub_closed"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."scrub_closed"() TO "postgres";

SELECT cron.schedule_in_database('bus-prune', '17 3 * * *', 'select bus.prune(); select bus.scrub_closed()', 'postgres', NULL, true);
