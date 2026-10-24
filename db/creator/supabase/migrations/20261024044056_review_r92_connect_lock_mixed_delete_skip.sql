SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.worker_upsert_social_account (
  p_user                uuid,
  p_platform            text,
  p_external_id         text,
  p_handle              text,
  p_followers           integer,
  p_platform_created_at timestamp with time zone,
  p_token               text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pf market.platform := p_platform::market.platform;
  a tracking.social_accounts;
  aid uuid;
begin
  -- FOR SHARE: serial dengan penutupan akun (status closed + profile.anonymize) — akun & token tidak tersimpan sesudah dibersihkan.
  perform 1 from market.profiles pr where pr.id = p_user for share;
  -- Aktif efektif (sama dengan claim_check / require_active_clipper): suspend yang sudah lewat tidak menunggu job lifecycle.
  if not exists (select 1 from market.profiles pr where pr.id = p_user
                  and (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now()))) then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.platform = pf and x.external_id = p_external_id for update;
  if found then
    if a.user_id <> p_user then
      raise exception 'social_taken' using errcode = 'P0001';
    end if;
    update tracking.social_accounts
       set handle = p_handle, followers = coalesce(p_followers, followers),
           platform_created_at = coalesce(p_platform_created_at, platform_created_at), status = 'verified', verified_at = now()
     where id = a.id;
    aid := a.id;
  else
    begin
      insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
      values (p_user, pf, p_external_id, p_handle, p_followers, p_platform_created_at) returning id into aid;
    exception when unique_violation then
      raise exception 'social_taken' using errcode = 'P0001';
    end;
  end if;
  if p_token is not null then
    perform api.store_social_token(aid, p_token);
  end if;
  return aid;
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  allowed text[] := bus.accepts(p_source, p ->> 'table');
  t regclass;
  pk text[];
  cols text[];
  upd text;
  n int := 0;
  h regprocedure;
begin
  -- Hanya tabel & kolom yang dikirim pemiliknya (bus/accept.sql, dari trigger bus.replicate pengirim): secret bus satu peer
  -- yang bocor tidak bisa menulis tabel lain di sini (uang, sanksi) atau kolom milik penerima.
  if allowed is null then
    raise exception 'bus_not_allowed:% %', p_source, p ->> 'table' using errcode = '42501';
  end if;
  t := (p ->> 'table')::regclass;
  pk := bus.pk_columns(t);
  if exists (select 1 from jsonb_object_keys(case when jsonb_typeof(p -> 'row') = 'object' then p -> 'row' else '{}' end) k
             where not k = any (allowed || pk)) then
    raise exception 'bus_not_allowed:% %', p_source, p ->> 'table' using errcode = '42501',
      detail = (select string_agg(k, ',') from jsonb_object_keys(p -> 'row') k where not k = any (allowed || pk));
  end if;
  -- delete hanya untuk tabel yang seluruh kolomnya milik pengirim: baris campuran (mis. profil dengan status/sanksi admin, org
  -- dengan fee admin) yang dihapus lalu dikirim ulang akan mengembalikan kolom milik penerima ke default. Dilewati + alert (tidak
  -- raise): delete baris campuran di pengirim (mis. hapus manual) tidak boleh menahan antrean selamanya.
  if p ->> 'op' = 'delete' and exists (select 1 from pg_attribute a where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                                                                    and not a.attname = any (allowed || pk)) then
    if to_regprocedure('ops.raise_alert(text, text, jsonb, interval)') is not null then
      execute 'select ops.raise_alert($1, $2, $3)' using 'bus.rejected_payload', 'critical',
        jsonb_build_object('topic', 'rep.row', 'op', 'delete', 'source', p_source, 'table', p ->> 'table', 'key', p -> 'key');
    end if;
    return;
  end if;
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = r.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    -- update dulu: baris dengan kolom milik sebagian (mis. status dari admin) tidak bisa lewat INSERT … ON CONFLICT (NOT NULL
    -- kolom lain dicek sebelum konflik). Baris belum ada → insert; kolom wajib lain tidak dikirim = baris milik project lain
    -- yang belum/tidak ada di sini → dilewati. Nilai sama persis (bus.resync) → tidak diubah dan hook tidak jalan: tabel
    -- append-only menolak UPDATE dan hook (accrual, keputusan) tidak boleh jalan dua kali.
    if upd is not null then
      execute format('update %1$s x set %2$s from jsonb_populate_record(null::%1$s, $1) r where %3$s and row(%4$s) is distinct from row(%5$s)',
                     t, upd, (select string_agg(format('x.%1$I = r.%1$I', c), ' and ') from unnest(pk) c),
                     (select string_agg(format('x.%I', c), ', ') from unnest(cols) c),
                     (select string_agg(format('r.%I', c), ', ') from unnest(cols) c))
        using p -> 'row';
      get diagnostics n = row_count;
    end if;
    if n = 0 then
      begin
        execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do nothing',
                       t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                       (select string_agg(format('%I', c), ', ') from unnest(pk) c))
          using p -> 'row';
        get diagnostics n = row_count;
      exception when not_null_violation then
        n := 0;
      end;
      if n = 0 then
        perform set_config('bus.applying', 'off', true);
        return;
      end if;
    end if;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;
