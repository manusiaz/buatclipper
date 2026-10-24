SET local check_function_bodies = off;

CREATE TABLE "market"."profiles" (
  "id"              uuid                     NOT NULL,
  "username"        text                     NOT NULL,
  "display_name"    text                     NOT NULL,
  "avatar_path"     text,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "status"          market.profile_status    NOT NULL DEFAULT 'active'::market.profile_status,
  "suspended_until" timestamp with time zone,
  "trust_score"     smallint                 NOT NULL DEFAULT 50,
  CONSTRAINT "profiles_avatar_own_folder" CHECK (((avatar_path IS NULL) OR (avatar_path ~~ ((id)::text || '/%'::text)))),
  CONSTRAINT "profiles_display_name_check" CHECK (((char_length(display_name) >= 1) AND (char_length(display_name) <= 50))),
  CONSTRAINT "profiles_pkey" PRIMARY KEY (id),
  CONSTRAINT "profiles_username_check" CHECK ((username ~ '^[a-z0-9_.]{3,30}$'::text)),
  CONSTRAINT "profiles_username_unique" UNIQUE (username)
);

ALTER TABLE "market"."profiles"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION api.ensure_profile (
  p_username      text,
  p_display_name  text,
  p_referral_code text DEFAULT NULL::text,
  p_avatar_path   text DEFAULT NULL::text
)
  RETURNS TABLE (
    id           uuid,
    username     text,
    display_name text,
    created      boolean
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  was_new boolean;
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if p_avatar_path is not null and (p_avatar_path not like uid::text || '/%' or p_avatar_path like '%..%') then
    perform market.fail('invalid:avatar_path', 'avatar harus di folder {uid}/', '22023');
  end if;
  begin
    insert into market.profiles as p (id, username, display_name, avatar_path)
    values (uid, lower(btrim(p_username)), btrim(p_display_name), p_avatar_path)
    on conflict on constraint profiles_pkey do update set username = excluded.username, display_name = excluded.display_name,
      avatar_path = coalesce(excluded.avatar_path, p.avatar_path)
      where p.status = 'active'
    returning (xmax = 0) into was_new;
  exception when unique_violation then
    perform market.fail('username_taken', lower(btrim(p_username)), '23505');
  end;
  if was_new is null then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif', '42501');
  end if;
  if was_new and nullif(btrim(p_referral_code), '') is not null then
    perform bus.emit('admin', 'referral.record', jsonb_build_object('user_id', uid, 'code', lower(btrim(p_referral_code))));
  end if;
  return query select pr.id, pr.username, pr.display_name, was_new from market.profiles pr where pr.id = uid;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.profile_anonymize (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 12), display_name = 'Akun dihapus', avatar_path = null
   where id = (p ->> 'user_id')::uuid;
$function$;

CREATE OR REPLACE FUNCTION bus_in.profile_ensure (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
  uname text := lower(btrim(p ->> 'username'));
begin
  if exists (select 1 from market.profiles x where x.id = v_user) then
    return;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from market.profiles x where x.username = uname) then
    uname := 'm_' || substr(replace(v_user::text, '-', ''), 1, 12);
  end if;
  while exists (select 1 from market.profiles x where x.username = uname) loop
    uname := 'm_' || substr(md5(random()::text), 1, 12);
  end loop;
  insert into market.profiles (id, username, display_name)
  values (v_user, uname, coalesce(nullif(left(btrim(p ->> 'display_name'), 50), ''), 'Anggota brand'));
end $function$;

CREATE VIEW "api"."my_profile" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path,
    trust_score,
    status,
    suspended_until,
    created_at
   FROM market.profiles
  WHERE (id = ( SELECT auth.uid() AS uid));

CREATE VIEW "api"."profiles" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path,
    created_at
   FROM market.profiles;

CREATE TRIGGER profiles_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.profiles
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('admin:username,display_name,avatar_path,created_at', 'brand:username,display_name,avatar_path');

CREATE POLICY "profiles_iss" ON "market"."profiles"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "profiles_public_read" ON "market"."profiles"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "avatars_own_update" ON "storage"."objects"
  FOR UPDATE
  TO "authenticated"
  USING (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

CREATE POLICY "avatars_own_write" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."profile_anonymize"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."profile_anonymize"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."profile_anonymize"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."profile_ensure"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."profile_ensure"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."profile_ensure"(jsonb) TO "postgres";

GRANT SELECT ("avatar_path") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("created_at") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("display_name") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("id") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("username") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ON TABLE "api"."my_profile" TO "authenticated";

GRANT SELECT ON TABLE "api"."profiles" TO "anon", "authenticated";
