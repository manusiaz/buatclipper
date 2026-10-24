SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.control_campaign (
  p_campaign uuid,
  p_action   text,
  p_params   jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  c market.campaigns;
  r market.rate_rules;
  newp jsonb;
  t timestamptz := clock_timestamp();
  new_deadline timestamptz;
  e jsonb;
  items jsonb := '[]';
  sub numeric := 0;
  pl record;
begin
  select * into c from market.campaigns where id = p_campaign for update;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  -- §4: topup = billing (brand_finance) tapi kontrak juga memberi brand_manager.
  if not ops.is_org_member(c.org_id, variadic case when p_action = 'topup'
                                                   then array['brand_owner', 'brand_manager', 'brand_finance']
                                                   else array['brand_owner', 'brand_manager'] end::market.org_role[]) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template then
    perform market.fail('invalid:template', 'template bukan campaign berjalan');
  end if;

  if p_action = 'pause' then
    if c.status <> 'live' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign live yang bisa dijeda');
    end if;
    update market.campaigns set status = 'paused' where id = c.id;
  elsif p_action = 'resume' then
    if c.status <> 'paused' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign paused yang bisa dilanjutkan');
    end if;
    if c.submit_deadline <= now() then
      perform market.fail('deadline_passed', 'perpanjang deadline dulu');
    end if;
    update market.campaigns set status = 'live' where id = c.id;
  elsif p_action = 'extend' then
    new_deadline := (prm ->> 'submit_deadline')::timestamptz;
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'perpanjang hanya untuk campaign terjadwal/berjalan');
    end if;
    if new_deadline is null or new_deadline <= greatest(now(), c.submit_deadline) then
      perform market.fail('invalid:submit_deadline', 'deadline baru harus setelah deadline lama');
    end if;
    update market.campaigns set submit_deadline = new_deadline where id = c.id;
  elsif p_action = 'raise_rate' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'naikkan rate hanya untuk campaign terjadwal/berjalan');
    end if;
    select * into r from market.rate_rules x
     where x.id = (prm ->> 'rule_id')::uuid and x.campaign_id = c.id and (x.effective_to is null or x.effective_to > now())
       for update;
    if r.id is null then
      perform market.fail('invalid:rule_id', 'rule aktif tidak ditemukan');
    end if;
    newp := prm -> 'params';
    perform market.check_rule_params(r.kind, newp);
    if not (case r.kind
             when 'per_1k_views' then market.jnum(newp -> 'rate') > market.jnum(r.params -> 'rate')
             when 'flat_per_post' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
             when 'milestone_bonus' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
                                         and market.jnum(newp -> 'threshold') <= market.jnum(r.params -> 'threshold')
             else jsonb_array_length(newp -> 'tiers') = jsonb_array_length(r.params -> 'tiers') and newp <> r.params
                  and not exists (select 1 from generate_series(0, jsonb_array_length(newp -> 'tiers') - 1) i
                                  where market.jnum(newp -> 'tiers' -> i -> 'rate') < market.jnum(r.params -> 'tiers' -> i -> 'rate')
                                     or market.jnum(newp -> 'tiers' -> i -> 'from') <> market.jnum(r.params -> 'tiers' -> i -> 'from')
                                     or market.jnum(newp -> 'tiers' -> i -> 'to') is distinct from market.jnum(r.params -> 'tiers' -> i -> 'to'))
           end) then
      perform market.fail('invalid:rate_not_higher', 'rate baru harus lebih tinggi dari rate lama');
    end if;
    -- Rule lama ditutup, rule baru berlaku untuk views sesudahnya (§10.5).
    update market.rate_rules set effective_to = t where id = r.id;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from, lineage_id)
    values (c.id, r.kind, r.reward_type_id, r.pool_id, r.platform, newp, t, coalesce(r.lineage_id, r.id));
  elsif p_action = 'notify_eligible' then
    -- F-B08 intervensi underspend: kabari clipper eligible yang belum pernah menerima pengumuman campaign ini.
    if c.status <> 'live' then
      perform market.fail('invalid_state:' || c.status, 'kabari clipper hanya untuk campaign berjalan');
    end if;
    perform market.announce_campaign(c.id);
  elsif p_action = 'topup' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'top-up hanya untuk campaign terjadwal/berjalan');
    end if;
    if jsonb_typeof(prm -> 'pools') is distinct from 'array' or jsonb_array_length(prm -> 'pools') = 0 then
      perform market.fail('invalid:pools', 'pools [{pool_id, amount}] wajib');
    end if;
    for e in select jsonb_array_elements(prm -> 'pools') loop
      select x.id, rt.idr_value_per_unit into pl from finance.reward_pools x join market.reward_types rt on rt.id = x.reward_type_id
       where x.id = (e ->> 'pool_id')::uuid and x.campaign_id = c.id;
      if pl.id is null or coalesce(market.jnum(e -> 'amount'), 0) <= 0 then
        perform market.fail('invalid:pool', 'pool campaign ini + amount > 0');
      end if;
      items := items || jsonb_build_array(jsonb_build_object('pool_id', pl.id, 'amount', market.jnum(e -> 'amount')));
      sub := sub + market.jnum(e -> 'amount') * pl.idr_value_per_unit;
    end loop;
    perform finance.issue_invoice(c.org_id, c.id, 'topup', sub, 0, null, items);
  elsif p_action = 'end_early' then
    if c.status in ('live', 'paused') then
      -- deadline ikut maju (replika ke creator & brand: submit ditutup; settle tidak menunggu deadline asli, lihat run_lifecycle)
      update market.campaigns set status = 'tracking', submit_deadline = least(submit_deadline, clock_timestamp()) where id = c.id;
    elsif c.status in ('draft', 'in_review', 'scheduled') then
      update market.campaigns set status = 'cancelled' where id = c.id;
      update finance.invoices set status = 'void' where campaign_id = c.id and status = 'issued';
    else
      perform market.fail('invalid_state:' || c.status, 'campaign sudah selesai');
    end if;
    update market.claims set status = 'released' where campaign_id = c.id and status = 'open';
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
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
