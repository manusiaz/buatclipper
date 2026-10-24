SET local check_function_bodies = off;

DROP FUNCTION "bus"."apply_row"(jsonb);

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
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc) using e -> 'payload';
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION bus.accepts (
  p_source text,
  p_table  text
)
  RETURNS text[]
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select v.cols from (values
    ('admin', 'market.campaigns', array['status', 'submit_deadline', 'view_window_days']),
    ('admin', 'market.claims', array['campaign_id', 'user_id', 'status', 'expires_at', 'created_at']),
    ('admin', 'market.profiles', array['status', 'suspended_until', 'trust_score']),
    ('admin', 'ops.settings', array['value', 'updated_by', 'updated_at']),
    ('admin', 'tracking.submissions', array['status', 'counted_views', 'locked_at', 'next_poll_at']),
    ('brand', 'market.campaigns', array['org_id', 'title', 'type', 'platforms', 'required_hashtags', 'required_mentions', 'required_links', 'min_duration_sec', 'max_duration_sec', 'review_mode', 'min_followers', 'min_account_age_days', 'max_clips_per_clipper', 'allow_video_reuse']),
    ('brand', 'market.org_links', array['approved_at', 'revoked_at', 'created_at']),
    ('brand', 'market.org_members', array['role', 'created_at']),
    ('brand', 'market.organizations', array['name', 'is_agency', 'status', 'verified_at', 'created_at'])
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$function$;

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

REVOKE ALL ON FUNCTION "bus"."accepts"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."accepts"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."accepts"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."apply_row"(jsonb, text) TO "postgres";
