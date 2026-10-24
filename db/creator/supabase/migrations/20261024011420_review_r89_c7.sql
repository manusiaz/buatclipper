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
    execute format('select %s($1)', h::regproc)  -- _source = pengirim terautentikasi (handler memvalidasi isi per pengirim)
      using e -> 'payload' || jsonb_build_object('_source', p_source);
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

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
