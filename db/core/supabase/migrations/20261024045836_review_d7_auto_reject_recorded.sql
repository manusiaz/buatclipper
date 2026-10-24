SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.appeal_submission (
  p_submission uuid,
  p_message    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  s tracking.submissions;
  pr market.profiles;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null or s.user_id <> uid then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.status is distinct from 'active' then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_message, ''))) not between 1 and 1000 then
    perform market.fail('invalid:message', 'alasan banding 1–1000 karakter');
  end if;
  if s.status <> 'rejected' then
    perform market.fail('invalid_state:' || s.status, 'banding hanya untuk submisi yang ditolak');
  end if;
  -- Penolakan otomatis (syarat campaign/claim/kuota, tracking.reject_auto) tidak bisa dibanding: overturn tidak mengulang cek itu.
  if exists (select 1 from trust.review_decisions d where d.target_type = 'submission' and d.target_id = s.id and d.decision = 'reject'
               and d.reason_code like 'system:%') then
    perform market.fail('appeal_closed', 'penolakan otomatis tidak bisa dibanding');
  end if;
  -- Campaign selesai (dana sisa bisa di-refund/rollover) → banding ditutup; banding yang berjalan menahan settle.
  if exists (select 1 from market.campaigns c where c.id = s.campaign_id and c.status in ('settling', 'settled', 'cancelled')) then
    perform market.fail('appeal_closed', 'campaign sudah selesai, banding ditutup');
  end if;
  -- Clip pengganti sudah memenuhi max_clips_per_clipper → banding clip lama tidak boleh menambah clip berbayar
  -- (banding yang berjalan sendiri ikut terhitung di claim_check, jadi pengganti tak bisa dikirim selama banding).
  -- Kuota clip per (campaign, clipper) diserialkan dengan worker_create_submission.
  perform pg_advisory_xact_lock(hashtextextended('clip_quota:' || s.campaign_id || ':' || uid, 0));
  if (select count(*) from tracking.submissions t where t.campaign_id = s.campaign_id and t.user_id = uid and t.id <> s.id
        and t.status not in ('rejected', 'rejected_final'))
     >= (select c.max_clips_per_clipper from market.campaigns c where c.id = s.campaign_id) then
    perform market.fail('appeal_replaced', 'clip pengganti sudah dikirim, banding tidak tersedia');
  end if;
  begin
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, message)
    values ('submission', s.id, uid, 'appeal', btrim(p_message));
  exception when unique_violation then
    perform market.fail('appeal_used', 'banding hanya sekali per submisi');
  end;
  update tracking.submissions set status = 'appealed' where id = s.id;
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
  claim_ok boolean;
  acc tracking.social_accounts;
  why text;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found or s.status <> 'validating' then
    return;
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  -- Claim & keanggotaan org dicek creator dari replika yang bisa tertinggal: released (end_early, ban, tutup akun) tidak diterima;
  -- expired diterima bila submisi tercatat di creator sebelum kedaluwarsa (job expire di sini bisa lebih dulu dari replika).
  update market.claims set status = 'submitted' where id = s.claim_id and status = 'open';
  claim_ok := found or exists (select 1 from market.claims k  -- expired → submitted bukan transisi S-02: claim dibiarkan expired
                                where k.id = s.claim_id and k.status = 'expired' and k.expires_at > s.created_at);
  -- Creator menerima submisi dari replika status campaign yang bisa tertinggal (mis. dibatalkan / sudah settle saat bus telat):
  -- campaign yang tidak lagi menerima klip → ditolak tanpa penalti Trust Score (bukan kesalahan clipper) + kabar.
  if c.status not in ('live', 'paused', 'tracking', 'exhausted') then
    perform tracking.reject_auto(s, 'campaign_closed', 'Campaign sudah tidak menerima klip saat submisi kamu tercatat.');
    return;
  end if;
  -- R67: anggota org pemilik (langsung / lewat agency) tidak boleh mengklip campaign org sendiri — bergabung setelah claim pun.
  if not claim_ok
     or exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = s.user_id)
     or exists (select 1 from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
                 where l.client_org_id = c.org_id and l.approved_at is not null and l.revoked_at is null and m.user_id = s.user_id) then
    perform tracking.reject_auto(s, case when claim_ok then 'own_org' else 'claim_released' end,
                                 case when claim_ok then 'Kamu anggota organisasi pemilik campaign ini.'
                                      else 'Claim kamu sudah tidak aktif saat submisi tercatat.' end);
    return;
  end if;
  -- Kuota clip per (campaign, clipper) dicek creator dari replika; banding clip lama di sini bisa berjalan bersamaan (advisory lock
  -- hanya mengunci di satu DB) → dicek ulang di bawah lock yang sama dengan appeal_submission; yang tiba belakangan ditolak.
  perform pg_advisory_xact_lock(hashtextextended('clip_quota:' || s.campaign_id || ':' || s.user_id, 0));
  if (select count(*) from tracking.submissions t where t.campaign_id = s.campaign_id and t.user_id = s.user_id and t.id <> s.id
        and t.status not in ('rejected', 'rejected_final')) >= c.max_clips_per_clipper then
    perform tracking.reject_auto(s, 'clip_quota', 'Batas clip per clipper di campaign ini sudah terpenuhi.');
    return;
  end if;
  -- Syarat isi campaign dicek creator dari replika isi yang bisa tertinggal (brand → creator telat): dicek ulang terhadap campaign
  -- di sini (isi terkunci sejak diajukan). Tag wajib caption tidak bisa (caption tiba bersama snapshot).
  select * into acc from tracking.social_accounts a where a.id = s.social_account_id;
  why := case
    when not (s.platform = any (c.platforms)) then 'platform'
    when coalesce(acc.followers, 0) < c.min_followers then 'followers'
    when c.min_account_age_days > 0 and (acc.platform_created_at is null
                                         or acc.platform_created_at > s.created_at - make_interval(days => c.min_account_age_days))
      then 'account_age'
    when s.duration_sec < c.min_duration_sec or s.duration_sec > c.max_duration_sec then 'duration'
    when not c.allow_video_reuse and exists (select 1 from tracking.submissions t where t.platform = s.platform and t.post_id = s.post_id
                                                                                  and t.campaign_id <> c.id)
      then 'video_reuse'
  end;
  if why is not null then
    perform tracking.reject_auto(s, why, case why
      when 'platform' then 'Platform akun ini tidak termasuk campaign.'
      when 'followers' then 'Followers akun belum memenuhi syarat campaign.'
      when 'account_age' then 'Umur akun belum memenuhi syarat campaign.'
      when 'duration' then 'Durasi video di luar syarat campaign.'
      else 'Video ini sudah dipakai di campaign lain.' end);
    return;
  end if;
  -- Profil diblokir/ditutup selagi submisi di jalan (replika status di creator tertinggal; ban & tutup akun hanya menyapu submisi
  -- yang sudah ada di sini) → ditolak tanpa penalti; jalur auto akan gagal not_eligible:profile_inactive dan submisi tertahan.
  if (select p.status::text from market.profiles p where p.id = s.user_id) in ('banned', 'closed') then
    perform tracking.reject_auto(s, 'profile_inactive', 'Akun tidak aktif saat submisi tercatat.', false);
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

CREATE OR REPLACE FUNCTION tracking.reject_auto (
  p_sub    tracking.submissions,
  p_code   text,
  p_reason text,
  p_notify boolean              DEFAULT true
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  update tracking.submissions set status = 'rejected' where id = p_sub.id;
  insert into trust.review_decisions (target_type, target_id, decision, reason_code, message)
  values ('submission', p_sub.id, 'reject', 'system:' || p_code, p_reason);
  if p_notify then
    perform ops.enqueue_notification(p_sub.user_id, 'submission.rejected', market.campaign_ref(p_sub.campaign_id)
                                     || jsonb_build_object('submission_id', p_sub.id, 'url', p_sub.url, 'platform', p_sub.platform,
                                                           'final', true, 'reason', p_reason));
  end if;
end $function$;

REVOKE ALL ON FUNCTION "tracking"."reject_auto"(tracking.submissions, text, text, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."reject_auto"(tracking.submissions, text, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."reject_auto"(tracking.submissions, text, text, boolean) TO "postgres";
