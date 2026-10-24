SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bus_receive (
  p_source text,
  p_events jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  e jsonb;
  h regprocedure;
  applied int := 0;
  skipped int := 0;
begin
  if jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'invalid:events' using errcode = 'P0001';
  end if;
  for e in select x from jsonb_array_elements(p_events) x loop
    -- klaim event dulu: kiriman kembar yang berjalan bersamaan (relay mengulang saat request pertama masih di DB) menunggu
    -- transaksi pertama lalu dilewati, bukan gagal duplicate key → 500 → backoff. Handler raise → klaim ikut batal.
    insert into bus.inbox (id, source, topic) values ((e ->> 'id')::uuid, p_source, e ->> 'topic') on conflict (id) do nothing;
    if not found then
      skipped := skipped + 1;
      continue;
    end if;
    if e ->> 'topic' = 'rep.row' then  -- replikasi baris: handler bawaan, dibatasi allowlist pengirim (bus.accepts)
      perform bus.apply_row(e -> 'payload', p_source);
      applied := applied + 1;
      continue;
    end if;
    -- topik hanya dari pengirim yang memang memanggil bus.emit-nya (bus.accepts_topic); uji.ping = handler e2e/bus.sh yang
    -- hanya ada selama uji berjalan
    if not bus.accepts_topic(p_source, e ->> 'topic') and e ->> 'topic' <> 'uji.ping' then
      raise exception 'bus_not_allowed:% %', p_source, e ->> 'topic' using errcode = '42501';
    end if;
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc)  -- pengirim bus.ping = pengirim yang terautentikasi, bukan isi payload
      using case when e ->> 'topic' = 'bus.ping' then e -> 'payload' || jsonb_build_object('source', p_source) else e -> 'payload' end;
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

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
  -- deleted_ = nama profil yang dihapus (profile.anonymize): direservasi, kalau tidak anonimisasi bentrok unik dan antrean
  -- admin → creator macet
  if lower(btrim(p_username)) like 'deleted\_%' then
    perform market.fail('username_taken', lower(btrim(p_username)), '23505');
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

CREATE OR REPLACE FUNCTION bus.accepts_topic (
  p_source text,
  p_topic  text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select (p_source, p_topic) in (
    ('admin', 'profile.anonymize'),
    ('admin', 'social.reset'),
    ('brand', 'profile.ensure')
  );
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
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 22), display_name = 'Akun dihapus', avatar_path = null
   where id = v_user;
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = v_user);
  delete from tracking.social_accounts a
   where a.user_id = v_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = v_user;
end $function$;

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
  if uname is null or uname !~ '^[a-z0-9_.]{3,30}$' or uname like 'deleted\_%' or exists (select 1 from market.profiles x where x.username = uname) then
    uname := 'm_' || substr(replace(v_user::text, '-', ''), 1, 12);
  end if;
  while exists (select 1 from market.profiles x where x.username = uname) loop
    uname := 'm_' || substr(md5(random()::text), 1, 12);
  end loop;
  insert into market.profiles (id, username, display_name)
  values (v_user, uname, coalesce(nullif(left(btrim(p ->> 'display_name'), 50), ''), 'Anggota brand'));
end $function$;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."accepts_topic"(text, text) TO "postgres";
