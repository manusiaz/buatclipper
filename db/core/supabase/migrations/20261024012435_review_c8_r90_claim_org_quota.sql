SET local check_function_bodies = off;

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
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found or s.status <> 'validating' then
    return;
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  -- Claim & keanggotaan org dicek creator dari replika yang bisa tertinggal: released (end_early, ban, tutup akun) tidak diterima;
  -- expired diterima bila submisi tercatat di creator sebelum kedaluwarsa (job expire di sini bisa lebih dulu dari replika).
  update market.claims set status = 'submitted'
   where id = s.claim_id and (status = 'open' or (status = 'expired' and expires_at > s.created_at));
  claim_ok := found;
  -- Creator menerima submisi dari replika status campaign yang bisa tertinggal (mis. dibatalkan / sudah settle saat bus telat):
  -- campaign yang tidak lagi menerima klip → ditolak tanpa penalti Trust Score (bukan kesalahan clipper) + kabar.
  if c.status not in ('live', 'paused', 'tracking', 'exhausted') then
    update tracking.submissions set status = 'rejected' where id = s.id;  -- banding ditolak appeal_closed (campaign selesai)
    perform ops.enqueue_notification(s.user_id, 'submission.rejected', market.campaign_ref(c.id)
                                     || jsonb_build_object('submission_id', s.id, 'url', s.url, 'platform', s.platform, 'final', true,
                                                           'reason', 'Campaign sudah tidak menerima klip saat submisi kamu tercatat.'));
    return;
  end if;
  -- R67: anggota org pemilik (langsung / lewat agency) tidak boleh mengklip campaign org sendiri — bergabung setelah claim pun.
  if not claim_ok
     or exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = s.user_id)
     or exists (select 1 from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
                 where l.client_org_id = c.org_id and l.approved_at is not null and l.revoked_at is null and m.user_id = s.user_id) then
    update tracking.submissions set status = 'rejected' where id = s.id;
    perform ops.enqueue_notification(s.user_id, 'submission.rejected', market.campaign_ref(c.id)
                                     || jsonb_build_object('submission_id', s.id, 'url', s.url, 'platform', s.platform, 'final', true,
                                                           'reason', case when claim_ok then 'Kamu anggota organisasi pemilik campaign ini.'
                                                                          else 'Claim kamu sudah tidak aktif saat submisi tercatat.' end));
    return;
  end if;
  -- Kuota clip per (campaign, clipper) dicek creator dari replika; banding clip lama di sini bisa berjalan bersamaan (advisory lock
  -- hanya mengunci di satu DB) → dicek ulang di bawah lock yang sama dengan appeal_submission; yang tiba belakangan ditolak.
  perform pg_advisory_xact_lock(hashtextextended('clip_quota:' || s.campaign_id || ':' || s.user_id, 0));
  if (select count(*) from tracking.submissions t where t.campaign_id = s.campaign_id and t.user_id = s.user_id and t.id <> s.id
        and t.status not in ('rejected', 'rejected_final')) >= c.max_clips_per_clipper then
    update tracking.submissions set status = 'rejected' where id = s.id;
    perform ops.enqueue_notification(s.user_id, 'submission.rejected', market.campaign_ref(c.id)
                                     || jsonb_build_object('submission_id', s.id, 'url', s.url, 'platform', s.platform, 'final', true,
                                                           'reason', 'Batas clip per clipper di campaign ini sudah terpenuhi.'));
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
