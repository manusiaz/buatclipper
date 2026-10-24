SET local check_function_bodies = off;

DROP FUNCTION "bus_in"."review_decision"(jsonb);

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

CREATE OR REPLACE FUNCTION bus_in.bus_ping (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into ops.bus_peers (source, pinged_at, stuck)
  select p ->> '_source', coalesce((p ->> 'at')::timestamptz, now()),
         case when jsonb_typeof(p -> 'stuck') = 'array' then p -> 'stuck' else '[]' end
   where p ->> '_source' in ('creator', 'brand')
  on conflict (source) do update set pinged_at = greatest(ops.bus_peers.pinged_at, excluded.pinged_at), stuck = excluded.stuck;
$function$;

CREATE OR REPLACE FUNCTION bus_in.notify_user (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  body jsonb := coalesce(p -> 'payload', '{}');
begin
  -- event per pengirim (email/push memakai template platform): brand = org.*, agency.*, campaign.invited; creator = social.*
  if not (p ->> '_source' = 'brand' and (p ->> 'event' ~ '^(org|agency)\.' or p ->> 'event' = 'campaign.invited')
          or p ->> '_source' = 'creator' and p ->> 'event' ~ '^social\.') then
    perform ops.raise_alert('bus.rejected_payload', 'critical', jsonb_build_object('topic', 'notify.user', 'source', p ->> '_source',
                                                                                  'event', p ->> 'event'));
    return;
  end if;
  if p ->> 'event' = 'campaign.invited' and body ? 'campaign_id' then
    body := body || jsonb_build_object('rate_per_1k', market.rate_per_1k((body ->> 'campaign_id')::uuid));
  end if;
  perform ops.enqueue_notification((p ->> 'user_id')::uuid, p ->> 'event', body, coalesce((p ->> 'email')::boolean, true));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.review_decision (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p ->> 'target_type' is distinct from 'org' then
    perform ops.raise_alert('bus.rejected_payload', 'critical', jsonb_build_object('topic', 'review.decision', 'source', p ->> '_source',
                                                                                  'target_type', p ->> 'target_type'));
    return;
  end if;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  select r.target_type, r.target_id, r.actor_id, r.decision, r.reason_code, r.message, r.note
    from jsonb_populate_record(null::trust.review_decisions, p) r;
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
  -- review_route dihitung creator dari replika isi campaign yang bisa tertinggal (mis. review_mode baru belum tiba di creator):
  -- syarat review manual menurut campaign yang disetujui di sini selalu menang.
  if c.review_mode in ('manual', 'brand') or (s.duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))
     or (c.type = 'music' and s.platform = 'tiktok') then
    s.review_route := 'manual';
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

REVOKE ALL ON FUNCTION "bus_in"."review_decision"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."review_decision"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."review_decision"(jsonb) TO "postgres";
