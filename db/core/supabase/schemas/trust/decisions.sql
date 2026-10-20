-- Keputusan review submisi (S-03) + Trust Score (F-C12, E-40). Internal: dipanggil api.record_review (admin/brand) dan
-- job lifecycle (auto-approve review brand, market.run_lifecycle → trust.auto_approve_overdue).
-- Delta skor dari config trust.score_deltas (approve naik, reject turun, banding gagal turun lebih banyak).

-- fn:apply_submission_decision — approve/auto_approve/reject dari in_review; overturn/uphold (atau approve/reject) dari appealed.
-- Approve → tracking + next_poll_at = now() supaya job track-due langsung mengambilnya. Notifikasi submission.approved/rejected.
create function trust.apply_submission_decision(p_submission uuid, p_decision text, p_actor uuid, p_reason text,
                                                p_message text, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
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

  update tracking.submissions
     set status = to_status, next_poll_at = case when to_status = 'tracking' then now() else next_poll_at end
   where id = s.id;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('submission', s.id, p_actor, logged, p_reason, p_message, p_note);
  if delta <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
    values (s.user_id, greatest(least(delta, 100), -100), score_reason, s.id::text, p_actor);
  end if;
  perform ops.enqueue_notification(s.user_id, case when to_status = 'tracking' then 'submission.approved' else 'submission.rejected' end,
                                   jsonb_build_object('submission_id', s.id, 'campaign_id', s.campaign_id,
                                                      'campaign_title', (select c.title from market.campaigns c where c.id = s.campaign_id),
                                                      'url', s.url, 'reason', p_reason,
                                                      'message', p_message, 'final', to_status = 'rejected_final'));
end $$;

-- F-B07: submisi campaign review brand yang tidak direview dalam public.market.brand_review_auto_approve_hours (72) → auto-approve.
-- Umur dihitung dari created_at submisi. Dipanggil job lifecycle (perform trust.auto_approve_overdue()).
create function trust.auto_approve_overdue() returns int
language plpgsql security definer set search_path = '' as $$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'public.market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
              and not (c.type = 'music' and s.platform = 'tiktok')  -- §11 sound TikTok wajib diverifikasi manual (R34-2)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $$;

-- job:trust-score — E-01.trust_score = 50 + Σ delta E-40, dibatasi 0–100. Hanya baris yang berubah yang ditulis.
-- Umur akun bersih (§12): tiap 30 hari tanpa reject, banding gagal, atau fraud flag → clean_tenure (config
-- trust.score_deltas.clean_tenure, default 1), satu kali per periode (ref_id = nomor periode sejak profil dibuat).
create function trust.recalc_scores() returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
  d_clean int := coalesce(((select st.value from ops.settings st where st.key = 'trust.score_deltas') ->> 'clean_tenure')::int, 1);
begin
  if d_clean <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id)
    select pr.id, greatest(least(d_clean, 100), -100), 'clean_tenure', x.period::text
      from market.profiles pr
      cross join lateral (select floor(extract(epoch from now() - pr.created_at) / (30 * 86400))::int as period) x
     where pr.status = 'active' and x.period >= 1
       and not exists (select 1 from trust.score_events e where e.user_id = pr.id and e.reason = 'clean_tenure' and e.ref_id = x.period::text)
       and not exists (select 1 from trust.score_events e where e.user_id = pr.id and e.delta < 0
                        and e.created_at > now() - interval '30 days')
       and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held', 'actioned')
                        and f.created_at > now() - interval '30 days'
                        and ((f.target_type = 'profile' and f.target_id = pr.id)
                          or (f.target_type = 'submission' and f.target_id in (select s.id from tracking.submissions s where s.user_id = pr.id))));
  end if;
  update market.profiles p set trust_score = x.score
    from (select pr.id, least(100, greatest(0, 50 + coalesce(sum(e.delta), 0)))::smallint as score
            from market.profiles pr left join trust.score_events e on e.user_id = pr.id
           group by pr.id) x
   where x.id = p.id and p.trust_score <> x.score;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function trust.apply_submission_decision(uuid, text, uuid, text, text, text), trust.auto_approve_overdue(),
  trust.recalc_scores() from public;
