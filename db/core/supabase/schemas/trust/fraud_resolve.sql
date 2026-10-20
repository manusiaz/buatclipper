-- Fraud queue (F-A06, §12). trust.raise_flag = satu-satunya jalan flag dibuat (worker track, post hilang, bridge identity FR-04/05):
-- satu flag terbuka per (target, sinyal); lonjakan > trust.fraud.flag_spike_per_hour flag/jam → alert admin.
-- p_status selain open/held = sinyal yang langsung ditindak otomatis (FR-06 post hilang, FR-08 koreksi turun).
create function trust.raise_flag(p_target_type text, p_target_id uuid, p_signal text, p_score numeric, p_details jsonb,
                                 p_status text default 'open') returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  fid uuid;
  n int;
begin
  if p_status in ('open', 'held') then
    insert into trust.fraud_flags (target_type, target_id, signal, score, status, details)
    values (p_target_type, p_target_id, p_signal, p_score, p_status, coalesce(p_details, '{}'))
    on conflict (target_type, target_id, signal) where status in ('open', 'held') do nothing
    returning id into fid;
  else
    insert into trust.fraud_flags (target_type, target_id, signal, score, status, details, resolved_at)
    values (p_target_type, p_target_id, p_signal, p_score, p_status, coalesce(p_details, '{}'), now())
    returning id into fid;
  end if;
  if fid is not null and p_status in ('open', 'held') then  -- blok withdraw (flag profil / payout): payout belum ditransfer ditahan
    if p_target_type = 'payout' then
      perform finance.hold_payouts(null, p_target_id, 'fraud_flag');
    elsif p_target_type = 'profile' then
      perform finance.hold_payouts(p_target_id, null, 'fraud_flag');
    end if;
  end if;
  if fid is not null then
    select count(*) into n from trust.fraud_flags f where f.created_at > now() - interval '1 hour';
    if n > (ops.cfg('trust.fraud.flag_spike_per_hour', '20'))::int then
      perform ops.raise_alert('fraud.flag_spike', 'warning', jsonb_build_object('flags_last_hour', n), interval '1 hour');
    end if;
  end if;
  return fid;
end $$;

-- Efek ban (§12, sama untuk fraud queue dan manajemen user F-A07): pending hangus, tracking berhenti, claim dilepas,
-- payout yang belum ditransfer ditahan, clipper dikabari. Ban login identity dipicu pemanggil.
create function trust.apply_ban(p_user uuid, p_reason text, p_payload jsonb) returns void
language plpgsql security definer set search_path = '' as $$
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
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  perform finance.hold_payouts(p_user, null, 'profile_banned');
  perform ops.enqueue_notification(p_user, 'account.banned', p_payload);
end $$;

-- Sanksi bertingkat (§12): hold (tahan earning/payout), reverse (earning pending kembali ke pool + submisi hangus),
-- suspend 30 hari, ban (permanen + pending hangus + ban Auth di identity lewat bridge), dismiss. Semua tercatat di audit log
-- dan riwayat Trust Score (E-40).
create function api.resolve_fraud_flag(p_flag uuid, p_action text, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  f trust.fraud_flags;
  target_user uuid;
  sub tracking.submissions;
  x record;
  score_delta smallint;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('warn', 'hold', 'reverse', 'suspend', 'ban', 'dismiss') then
    raise exception 'invalid:action' using errcode = 'P0001';
  end if;
  select * into f from trust.fraud_flags ff where ff.id = p_flag for update;
  if not found then
    raise exception 'not_found:fraud_flag' using errcode = 'P0002';
  end if;
  if f.status not in ('open', 'held') then
    raise exception 'invalid_state:%', f.status using errcode = 'P0001';
  end if;
  target_user := case f.target_type
    when 'profile' then f.target_id
    when 'submission' then (select s.user_id from tracking.submissions s where s.id = f.target_id)
    when 'social_account' then (select a.user_id from tracking.social_accounts a where a.id = f.target_id)
    when 'payout' then (select p.user_id from finance.payouts p where p.id = f.target_id) end;
  if f.target_type = 'submission' then
    select * into sub from tracking.submissions s where s.id = f.target_id for update;
  end if;
  if p_action = 'reverse' and f.target_type not in ('submission', 'profile') then
    raise exception 'invalid:action_for_target' using errcode = 'P0001';
  end if;

  if p_action = 'hold' then
    update trust.fraud_flags set status = 'held' where id = f.id;
    if sub.status = 'tracking' then
      update tracking.submissions set status = 'flagged' where id = sub.id;
    end if;
    if f.target_type = 'payout' then
      -- Instant requested sudah diteruskan ke penyedia (alur 11); menahannya membuka refund saat transfer berjalan.
      update finance.payouts set status = 'on_hold', hold_reason = 'fraud:' || f.signal
       where id = f.target_id and status = 'requested' and channel = 'batch';
    end if;
  elsif p_action = 'dismiss' then
    update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = f.id;
    if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                               and o.target_id = sub.id and o.status in ('open', 'held')) then
      update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
    end if;
  else
    update trust.fraud_flags set status = 'actioned', resolved_by = uid, resolved_at = now() where id = f.id;
    if p_action = 'reverse' then
      for x in select s.id, s.status from tracking.submissions s
                where (f.target_type = 'submission' and s.id = f.target_id)
                   or (f.target_type = 'profile' and s.user_id = f.target_id and s.status in ('tracking', 'flagged', 'locked'))
                order by s.id loop
        perform finance.reverse_earning(x.id, 'fraud:' || f.signal);
        if x.status in ('tracking', 'flagged') then
          update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
          perform ops.enqueue_notification(target_user, 'submission.forfeited',
                                           market.campaign_ref((select s.campaign_id from tracking.submissions s where s.id = x.id))
                                           || jsonb_build_object('submission_id', x.id, 'reason', 'fraud:' || f.signal));
        end if;
      end loop;
    elsif p_action = 'suspend' then
      update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days'
       where id = target_user and status in ('active', 'suspended');
      perform finance.hold_payouts(target_user, null, 'profile_suspended');
      perform ops.enqueue_notification(target_user, 'account.suspended',
                                       jsonb_build_object('until', now() + interval '30 days', 'signal', f.signal));
    elsif p_action = 'ban' then
      update market.profiles set status = 'banned' where id = target_user and status <> 'closed';
      perform trust.apply_ban(target_user, f.signal, jsonb_build_object('signal', f.signal, 'flag_id', f.id));
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', target_user));
    elsif p_action = 'warn' then
      perform ops.enqueue_notification(target_user, 'account.warned', jsonb_build_object('signal', f.signal));
    end if;
  end if;
  -- §12: setiap sanksi tercatat dan bisa dibanding sekali (trust.sanctions)
  if p_action <> 'dismiss' and target_user is not null then
    perform trust.record_sanction(target_user, p_action, f.id, p_note);
  end if;

  score_delta := case p_action when 'warn' then -5 when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $$;

revoke execute on function trust.apply_ban(uuid, text, jsonb), trust.raise_flag(text, uuid, text, numeric, jsonb, text), api.resolve_fraud_flag(uuid, text, text) from public;
grant execute on function api.resolve_fraud_flag(uuid, text, text) to authenticated;
