-- Review & banding (F-A02, F-A05, F-B07, F-C07, J-A2). Kode error: kepala api/_helpers.sql.

-- F-C07 banding 1× per submisi (unique index review_one_appeal_per_submission), S-03 rejected → appealed. Hanya pemilik
-- dengan profil aktif. Antre di moderasi admin (record_review target submission, keputusan overturn/uphold).
create function api.appeal_submission(p_submission uuid, p_message text) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Keputusan review. campaign (admin_ops): approve hanya kalau invoice campaign lunas → scheduled; reject → rejected.
-- submission: admin_moderator, atau brand_owner/brand_manager untuk campaign review_mode brand (submisi in_review saja);
-- banding (appealed) hanya admin. kyc (admin_moderator): catat keputusan identity tanpa PII + notifikasi kyc.*.
-- org (admin_ops): sama dengan manage_org verify/reject. Aksi admin tercatat di ops.audit_logs.
create function api.record_review(p_target_type text, p_target_id uuid, p_decision text, p_reason text default null,
                                  p_message text default null, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  s record;
  is_admin boolean;
begin
  if p_target_type = 'campaign' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    select * into c from market.campaigns where id = p_target_id for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if c.status <> 'in_review' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign in_review yang bisa direview');
    end if;
    if p_decision = 'approve' then
      if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'campaign' and i.status = 'paid') then
        perform market.fail('invoice_unpaid', 'invoice campaign belum lunas');
      end if;
      -- Paket managed (REV-3): jasa tim internal juga harus lunas sebelum campaign tayang.
      if exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'managed_service' and i.status = 'issued') then
        perform market.fail('invoice_unpaid', 'invoice paket managed belum lunas');
      end if;
      update market.campaigns set status = 'scheduled' where id = c.id;
    elsif p_decision = 'reject' then
      if nullif(btrim(p_reason), '') is null then
        perform market.fail('invalid:reason', 'penolakan wajib alasan');
      end if;
      update market.campaigns set status = 'rejected' where id = c.id;
    else
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('campaign', c.id, uid, p_decision, p_reason, p_message, p_note);
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[],
                              case p_decision when 'approve' then 'campaign.approved' else 'campaign.rejected' end,
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.campaign.' || p_decision, 'campaign:' || c.id, jsonb_build_object('status', c.status),
            jsonb_build_object('status', case p_decision when 'approve' then 'scheduled' else 'rejected' end, 'reason', p_reason));

  elsif p_target_type = 'submission' then
    if p_decision not in ('approve', 'reject', 'overturn', 'uphold') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    select sb.id, sb.status, sb.user_id, k.org_id, k.review_mode into s
      from tracking.submissions sb join market.campaigns k on k.id = sb.campaign_id where sb.id = p_target_id
       for update of sb; -- otorisasi brand memakai status yang sama dengan yang diubah keputusan (tidak balapan dengan reject+banding)
    if s.id is null then
      perform market.fail('not_found:submission', null, 'P0002');
    end if;
    is_admin := ops.has_admin('admin_moderator');
    if not is_admin and not (s.review_mode = 'brand' and s.status = 'in_review'
                             and s.user_id <> uid  -- tidak mereview clip sendiri (R67)
                             and ops.is_org_member(s.org_id, 'brand_owner', 'brand_manager')) then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2 atau brand_owner/brand_manager (review brand)', '42501');
    end if;
    perform trust.apply_submission_decision(s.id, p_decision, uid, p_reason, p_message, p_note);
    if is_admin then
      insert into ops.audit_logs (actor_id, action, target, before, after)
      values (uid, 'review.submission.' || p_decision, 'submission:' || s.id, jsonb_build_object('status', s.status),
              jsonb_build_object('status', (select x.status from tracking.submissions x where x.id = s.id), 'reason', p_reason));
    end if;

  elsif p_target_type = 'kyc' then
    -- Keputusan KYC diputus di identity (admin_kyc_decision); core hanya mencatat (tanpa PII) + mengabari user.
    if not ops.has_admin('admin_moderator') then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    if p_decision = 'reject' and nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if not exists (select 1 from market.profiles pr where pr.id = p_target_id) then
      perform market.fail('not_found:profile', null, 'P0002');
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('kyc', p_target_id, uid, p_decision, p_reason, p_message, p_note);
    -- Referral (F-C16) berlaku sejak KYC disetujui, bukan sejak withdraw pertama (earning di antaranya ikut dihitung).
    if p_decision = 'approve' then
      update market.referrals set qualified_at = now(),
             bonus_until = now() + make_interval(days => (ops.cfg('finance.referral_bonus_days', '90'))::int)
       where referred_id = p_target_id and qualified_at is null;
    end if;
    perform ops.enqueue_notification(p_target_id, case p_decision when 'approve' then 'kyc.approved' else 'kyc.rejected' end,
                                     jsonb_build_object('decision', p_decision, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.kyc.' || p_decision, 'profile:' || p_target_id, null, jsonb_build_object('reason', p_reason));

  elsif p_target_type = 'org' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    perform market.decide_org(p_target_id, p_decision, uid, p_reason, p_message, p_note);
  else
    perform market.fail('invalid:target_type', coalesce(p_target_type, 'null'));
  end if;
end $$;

revoke execute on function api.appeal_submission(uuid, text), api.record_review(text, uuid, text, text, text, text) from public;
grant execute on function api.appeal_submission(uuid, text), api.record_review(text, uuid, text, text, text, text) to authenticated;
