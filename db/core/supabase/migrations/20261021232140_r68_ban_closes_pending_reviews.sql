SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION trust.apply_ban (
  p_user    uuid,
  p_reason  text,
  p_payload jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  x record;
begin
  for x in select s.id, s.status from tracking.submissions s
            where s.user_id = p_user and s.status in ('tracking', 'flagged', 'locked') order by s.id loop
    perform finance.reverse_earning(x.id, 'ban:' || p_reason);
    if x.status in ('tracking', 'flagged') then
      update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
    end if;
  end loop;
  -- Submisi yang masih menunggu review/banding ditutup (transisi S-03 yang sah) supaya tidak bisa di-approve lalu tracking (R68).
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  perform finance.hold_payouts(p_user, null, 'profile_banned');
  perform ops.enqueue_notification(p_user, 'account.banned', p_payload);
end $function$;

CREATE OR REPLACE FUNCTION trust.apply_submission_decision (
  p_submission uuid,
  p_decision   text,
  p_actor      uuid,
  p_reason     text,
  p_message    text,
  p_note       text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  d jsonb := coalesce((select st.value from ops.settings st where st.key = 'trust.score_deltas'), '{}');
  d_ok int := coalesce((d ->> 'submission_approved')::int, 1);
  d_rej int := coalesce((d ->> 'submission_rejected')::int, -2);
  d_app int := coalesce((d ->> 'appeal_failed')::int, -3);
  to_status tracking.submission_status;
  logged text;
  delta int;
  score_reason text;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  if s.status = 'in_review' and p_decision in ('approve', 'auto_approve') then
    to_status := 'tracking'; logged := p_decision; delta := d_ok; score_reason := 'submission_approved';
  elsif s.status = 'in_review' and p_decision = 'reject' then
    to_status := 'rejected'; logged := 'reject'; delta := d_rej; score_reason := 'submission_rejected';
  elsif s.status = 'appealed' and p_decision in ('overturn', 'approve') then
    -- banding diterima: hapus efek reject sebelumnya + bonus approve
    to_status := 'tracking'; logged := 'overturn'; delta := d_ok - d_rej; score_reason := 'submission_approved';
  elsif s.status = 'appealed' and p_decision in ('uphold', 'reject') then
    to_status := 'rejected_final'; logged := 'uphold'; delta := d_app; score_reason := 'appeal_failed';
  else
    perform market.fail('invalid_state:' || s.status, format('keputusan %s tidak berlaku untuk submisi %s', p_decision, s.status));
  end if;
  if to_status in ('rejected', 'rejected_final') and nullif(btrim(p_reason), '') is null then
    perform market.fail('invalid:reason', 'penolakan wajib alasan standar');
  end if;
  -- Profil banned/closed tidak boleh kembali tracking (R68). FOR SHARE: serial dengan ban yang sedang mengubah profil.
  if to_status = 'tracking'
     and (select p.status::text from market.profiles p where p.id = s.user_id for share) in ('banned', 'closed') then
    perform market.fail('not_eligible:profile_inactive', 'profil diblokir');
  end if;

  update tracking.submissions
     set status = to_status, next_poll_at = case when to_status = 'tracking' then now() else next_poll_at end
   where id = s.id;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('submission', s.id, p_actor, logged, p_reason, p_message, p_note);
  if delta <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
    values (s.user_id, greatest(least(delta, 100), -100), score_reason, s.id::text, p_actor);
  end if;
  -- DS "notif selalu ada angka": approve + views, rate/1K, ±earning & perkiraan cair (finance.clip_estimate); reject + views.
  perform ops.enqueue_notification(s.user_id, case when to_status = 'tracking' then 'submission.approved' else 'submission.rejected' end,
                                   jsonb_build_object('submission_id', s.id, 'campaign_id', s.campaign_id,
                                                      'campaign_title', (select c.title from market.campaigns c where c.id = s.campaign_id),
                                                      'url', s.url, 'reason', p_reason,
                                                      'message', p_message, 'final', to_status = 'rejected_final',
                                                      'platform', s.platform, 'views', greatest(s.counted_views, coalesce(s.last_views, 0)))
                                   || case when to_status = 'tracking' then finance.clip_estimate(s.id) else '{}' end);
end $function$;

CREATE OR REPLACE FUNCTION trust.auto_approve_overdue()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'public.market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
              and not (c.type = 'music' and s.platform = 'tiktok')  -- §11 sound TikTok wajib diverifikasi manual (R34-2)
              and exists (select 1 from market.profiles p where p.id = s.user_id and p.status not in ('banned', 'closed'))
              and not (s.duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))  -- durasi wajib dicek manusia (R66)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $function$;
