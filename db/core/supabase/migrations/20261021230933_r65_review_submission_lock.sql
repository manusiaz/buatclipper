SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.record_review (
  p_target_type text,
  p_target_id   uuid,
  p_decision    text,
  p_reason      text DEFAULT NULL::text,
  p_message     text DEFAULT NULL::text,
  p_note        text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
    select sb.id, sb.status, k.org_id, k.review_mode into s
      from tracking.submissions sb join market.campaigns k on k.id = sb.campaign_id where sb.id = p_target_id
       for update of sb; -- otorisasi brand memakai status yang sama dengan yang diubah keputusan (tidak balapan dengan reject+banding)
    if s.id is null then
      perform market.fail('not_found:submission', null, 'P0002');
    end if;
    is_admin := ops.has_admin('admin_moderator');
    if not is_admin and not (s.review_mode = 'brand' and s.status = 'in_review'
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
end $function$;
