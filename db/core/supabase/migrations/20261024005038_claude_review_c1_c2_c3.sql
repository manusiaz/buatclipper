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
    ('brand', 'market.campaign_assets', array['campaign_id', 'kind', 'storage_path', 'url', 'size_bytes', 'audience', 'created_at']),
    ('brand', 'market.campaign_invites', array['invited_by', 'created_at']),
    ('brand', 'market.campaigns', array['org_id', 'slug', 'title', 'type', 'category_id', 'platforms', 'brief', 'managed_brief', 'required_hashtags', 'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls', 'faq', 'service_mode', 'review_mode', 'min_followers', 'min_account_age_days', 'min_trust_score', 'kyc_required', 'min_views', 'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility', 'is_template', 'content_version', 'created_by', 'created_at']),
    ('brand', 'market.org_links', array['approved_by', 'approved_at', 'revoked_at', 'created_at']),
    ('brand', 'market.org_members', array['role', 'added_by', 'created_at']),
    ('brand', 'market.organizations', array['name', 'org_type', 'legal_name', 'npwp', 'address', 'is_agency', 'status', 'verified_by', 'verified_at', 'created_by', 'created_at', 'updated_at']),
    ('creator', 'market.profiles', array['username', 'display_name', 'avatar_path', 'created_at']),
    ('creator', 'tracking.social_accounts', array['user_id', 'platform', 'external_id', 'handle', 'status', 'followers', 'platform_created_at', 'verified_at', 'created_at']),
    ('creator', 'tracking.submissions', array['claim_id', 'user_id', 'campaign_id', 'social_account_id', 'platform', 'post_id', 'url', 'posted_at', 'duration_sec', 'review_route', 'cover_hash', 'last_snapshot_at', 'last_views', 'created_at']),
    ('creator', 'tracking.view_snapshots', array['submission_id', 'taken_at', 'views', 'likes', 'comments', 'shares', 'is_final', 'raw'])
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

CREATE OR REPLACE FUNCTION bus_in.market_campaigns_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
begin
  if p_op <> 'upsert' then
    return;
  end if;
  select * into c from market.campaigns where id = (p_row ->> 'id')::uuid for update;
  if c.id is null or c.content_version <= coalesce(c.submitted_version, 0) then
    return;
  end if;
  if c.status = 'rejected' then
    update market.campaigns set status = 'draft' where id = c.id;
  elsif c.status = 'in_review' then
    update market.campaigns set status = 'rejected' where id = c.id;
    update market.campaigns set status = 'draft' where id = c.id;
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.rejected',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', 'content_changed'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.resubmit_required', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version));
  elsif c.status <> 'draft' then
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.content_drift', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version, 'status', c.status));
  end if;
exception when others then
  perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', p_row ->> 'id', 'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_submissions_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.decide_new_submission((p_row ->> 'id')::uuid);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', p_row ->> 'id', 'step', 'decide',
                                                                               'error', sqlerrm));
  begin  -- jangan tertahan validating (lifecycle menunggu submisi aktif): antre review manual
    update tracking.submissions set status = 'in_review' where id = (p_row ->> 'id')::uuid and status = 'validating';
  exception when others then
    null;
  end;
end $function$;

CREATE OR REPLACE FUNCTION market.template_stays_draft()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if new.is_template and new.status = 'in_review' then
    raise exception 'invalid:template' using errcode = '23514', detail = 'template tidak bisa diajukan; duplikat dulu';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION tracking.decide_new_submission (
  p_submission uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  c market.campaigns;
  dup record;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found or s.status <> 'validating' then
    return;
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  update market.claims set status = 'submitted' where id = s.claim_id and status = 'open';
  -- Creator menerima submisi dari replika status campaign yang bisa tertinggal (mis. dibatalkan / sudah settle saat bus telat):
  -- campaign yang tidak lagi menerima klip → ditolak tanpa penalti Trust Score (bukan kesalahan clipper) + kabar.
  if c.status not in ('live', 'paused', 'tracking', 'exhausted') then
    update tracking.submissions set status = 'rejected' where id = s.id;  -- banding ditolak appeal_closed (campaign selesai)
    perform ops.enqueue_notification(s.user_id, 'submission.rejected', market.campaign_ref(c.id)
                                     || jsonb_build_object('submission_id', s.id, 'url', s.url, 'platform', s.platform, 'final', true,
                                                           'reason', 'Campaign sudah tidak menerima klip saat submisi kamu tercatat.'));
    return;
  end if;
  -- Profil diblokir/ditutup selagi submisi di jalan (replika status di creator tertinggal; ban & tutup akun hanya menyapu submisi
  -- yang sudah ada di sini) → ditolak tanpa penalti; jalur auto akan gagal not_eligible:profile_inactive dan submisi tertahan.
  if (select p.status::text from market.profiles p where p.id = s.user_id) in ('banned', 'closed') then
    update tracking.submissions set status = 'rejected' where id = s.id;
    return;
  end if;
  update tracking.submissions set status = 'in_review' where id = s.id;
  if s.review_route = 'auto' then
    perform trust.apply_submission_decision(s.id, 'auto_approve', null, null, null, 'auto');
  end if;
  if s.cover_hash is not null then
    select array_agg(t.id order by t.created_at) ids, array_agg(distinct t.user_id) users into dup
      from (select t.id, t.user_id, t.created_at from tracking.submissions t
             where t.cover_hash is not null and t.created_at > now() - interval '90 days' and t.social_account_id <> s.social_account_id
               and t.id <> s.id
               and bit_count((t.cover_hash # s.cover_hash)::bit(64)) <= (ops.cfg('trust.fraud.cover_distance', '6'))::int
             order by t.created_at limit 20) t;
    if dup.ids is not null then
      perform trust.raise_flag('submission', s.id, 'FR-07', 60,
                               jsonb_build_object('duplicates', to_jsonb(dup.ids),
                                                  'related_user_ids', to_jsonb(array_remove(dup.users, s.user_id))));
    end if;
  end if;
  if c.review_mode = 'brand' and s.review_route = 'manual' then
    begin  -- kabar saja: anggota brand yang profilnya belum tiba (FK notifikasi) tidak boleh membatalkan keputusan
      perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'submission.pending_review',
                                market.campaign_ref(c.id) || jsonb_build_object('submission_id', s.id));
    exception when others then
      perform ops.raise_alert('tracking.notify_failed', 'warning', jsonb_build_object('submission_id', s.id, 'error', sqlerrm));
    end;
  end if;
end $function$;

REVOKE ALL ON FUNCTION "bus"."accepts"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."accepts"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."accepts"(text, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."apply_row"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."apply_row"(jsonb, text) TO "postgres";
