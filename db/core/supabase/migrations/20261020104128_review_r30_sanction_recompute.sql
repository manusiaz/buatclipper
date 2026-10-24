SET local check_function_bodies = off;

DROP VIEW "api"."sanctions";

DROP FUNCTION "trust"."record_sanction"(uuid, text, uuid, text);

ALTER TABLE "trust"."sanctions"
  ADD COLUMN "until" timestamp WITH time zone;

ALTER TABLE "trust"."sanctions"
  ADD COLUMN "login_blocked" boolean NOT NULL DEFAULT false;

ALTER TABLE "trust"."sanctions"
  ADD COLUMN "lifted_at" timestamp WITH time zone;

CREATE OR REPLACE FUNCTION api.appeal_sanction (
  p_sanction uuid,
  p_message  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  s trust.sanctions;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  perform trust.file_appeal(p_sanction, uid, p_message);
end $function$;

CREATE OR REPLACE FUNCTION api.decide_sanction_appeal (
  p_sanction uuid,
  p_decision text,
  p_note     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  s trust.sanctions;
  restore smallint;
  sub uuid;
  still_banned boolean;
  sus_until timestamptz;
  login_until timestamptz;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('upheld', 'overturned') then
    raise exception 'invalid:decision' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  select * into s from trust.sanctions x where x.id = p_sanction for update;
  if not found then
    raise exception 'not_found:sanction' using errcode = 'P0002';
  end if;
  if s.appealed_at is null or s.decision is not null then
    raise exception 'invalid_state:appeal' using errcode = 'P0001';
  end if;
  update trust.sanctions set decision = p_decision, decision_note = left(btrim(p_note), 500), decided_by = uid, decided_at = now()
   where id = s.id;
  if p_decision = 'overturned' then
    if s.kind in ('suspend', 'ban') and s.lifted_at is null then
      -- Status akun dihitung ulang dari sanksi lain yang masih berlaku (R30-4): ban lain → tetap; suspend lain → sampai until
      -- terjauh; tidak ada → aktif. Login identity disamakan (R30-3): sisa ban login berdurasi, atau dibuka.
      perform 1 from market.profiles p where p.id = s.user_id for update;
      select exists (select 1 from trust.sanctions o where o.user_id = s.user_id and o.id <> s.id and o.kind = 'ban'
                      and o.decision is distinct from 'overturned' and o.lifted_at is null) into still_banned;
      select max(o.until), max(o.until) filter (where o.login_blocked) into sus_until, login_until
        from trust.sanctions o where o.user_id = s.user_id and o.id <> s.id and o.kind = 'suspend'
         and o.decision is distinct from 'overturned' and o.lifted_at is null and o.until > now();
      if not still_banned then
        update market.profiles set status = (case when sus_until is null then 'active' else 'suspended' end)::market.profile_status, suspended_until = sus_until
         where id = s.user_id and status in ('suspended', 'banned');
        if s.login_blocked or s.kind = 'ban' then
          perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', s.user_id,
                   'unban', login_until is null,
                   'duration', case when login_until is not null then ceil(extract(epoch from login_until - now()) / 3600)::int || 'h' end));
        end if;
      end if;
    elsif s.kind = 'hold' and s.flag_id is not null then
      update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = s.flag_id and status = 'held';
      sub := (select f.target_id from trust.fraud_flags f where f.id = s.flag_id and f.target_type = 'submission');
      if sub is not null and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission' and o.target_id = sub
                                           and o.status in ('open', 'held')) then
        update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now())
         where id = sub and status = 'flagged';
      end if;
    end if;
    restore := case s.kind when 'warn' then 5 when 'reverse' then 10 when 'suspend' then 20 when 'ban' then 50 end;
    if restore is not null and s.flag_id is not null then  -- penalti Trust Score hanya dari fraud queue
      insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
      values (s.user_id, restore, 'appeal_overturned', s.id::text, uid);
    end if;
  end if;
  perform ops.enqueue_notification(s.user_id, 'sanction.appeal_decided',
                                   jsonb_build_object('sanction_id', s.id, 'kind', s.kind, 'decision', p_decision));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'sanction.appeal_decide', 'sanction:' || s.id, jsonb_build_object('kind', s.kind, 'user_id', s.user_id),
          jsonb_build_object('decision', p_decision, 'note', left(btrim(p_note), 500)));
end $function$;

CREATE OR REPLACE FUNCTION api.manage_user (
  p_user   uuid,
  p_action text,
  p_params jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  pr market.profiles;
  delta int;
  days int;
  until_at timestamptz;
begin
  if not ops.has_admin('admin_ops', 'admin_moderator') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_moderator aal2', '42501');
  end if;
  select * into pr from market.profiles where id = p_user for update;
  if pr.id is null then
    perform market.fail('not_found:profile', null, 'P0002');
  end if;
  if nullif(btrim(coalesce(prm ->> 'reason', prm ->> 'note')), '') is null then
    perform market.fail('invalid:reason', 'aksi admin atas user wajib alasan');
  end if;
  if p_action = 'trust_override' then
    delta := market.jnum(prm -> 'delta')::int;
    if delta is null or delta = 0 or delta not between -100 and 100 then
      perform market.fail('invalid:delta', 'delta -100..100, bukan 0');
    end if;
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (pr.id, delta, 'admin_override', left(prm ->> 'note', 200), uid);
    update market.profiles set trust_score = least(100, greatest(0, 50 + (select coalesce(sum(e.delta), 0) from trust.score_events e
                                                                           where e.user_id = pr.id)))
     where id = pr.id;
  elsif p_action = 'suspend' then
    -- {until}: sampai waktu persis (ban login berdurasi dari admin-auth); {days}: 1–365 hari.
    if prm ? 'until' then
      until_at := (prm ->> 'until')::timestamptz;
      if until_at is null or until_at <= now() then
        perform market.fail('invalid:until', 'until harus di masa depan');
      end if;
    else
      days := market.jnum(prm -> 'days')::int;
      if days is null or days not between 1 and 365 then
        perform market.fail('invalid:days', 'suspend 1–365 hari');
      end if;
      until_at := now() + make_interval(days => days);
    end if;
    if pr.status not in ('active', 'suspended') then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'suspended', suspended_until = until_at where id = pr.id;
    update market.claims set status = 'released' where user_id = pr.id and status = 'open';
    perform finance.hold_payouts(pr.id, null, 'profile_suspended');
    perform ops.enqueue_notification(pr.id, 'account.suspended',
                                     jsonb_build_object('until', until_at, 'reason', prm ->> 'reason'));
    -- {until} datang dari ban login berdurasi (admin Users → identity admin-auth): login ikut diblokir
    perform trust.record_sanction(pr.id, 'suspend', null, prm ->> 'reason', until_at, prm ? 'until');
  elsif p_action = 'unsuspend' then
    if pr.status <> 'suspended' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id;
    update trust.sanctions set lifted_at = now() where user_id = pr.id and kind = 'suspend' and lifted_at is null;
  elsif p_action = 'ban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'banned' where id = pr.id;
    -- Paritas dengan ban fraud queue (AA-7): pending hangus, tracking berhenti, payout ditahan, clipper dikabari.
    perform trust.apply_ban(pr.id, 'admin', jsonb_build_object('reason', prm ->> 'reason'));
    perform trust.record_sanction(pr.id, 'ban', null, prm ->> 'reason', null, true);
  elsif p_action = 'unban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id and status in ('banned', 'suspended');
    update trust.sanctions set lifted_at = now() where user_id = pr.id and kind in ('ban', 'suspend') and lifted_at is null;
  else
    perform market.fail('invalid:action', p_action);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'user.' || p_action, 'profile:' || pr.id,
          jsonb_build_object('status', pr.status, 'trust_score', pr.trust_score, 'suspended_until', pr.suspended_until),
          prm || jsonb_build_object('status', (select p.status from market.profiles p where p.id = pr.id),
                                    'trust_score', (select p.trust_score from market.profiles p where p.id = pr.id)));
end $function$;

CREATE OR REPLACE FUNCTION api.record_sanction_appeal (
  p_sanction uuid,
  p_message  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_support', 'admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  perform trust.file_appeal(p_sanction, null, p_message);
  insert into ops.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'sanction.appeal_record', 'sanction:' || p_sanction, jsonb_build_object('via', 'support'));
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_fraud_flag (
  p_flag   uuid,
  p_action text,
  p_note   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
      -- peringatan = earning tetap jalan: submisi yang ditahan flag ini lanjut tracking bila tak ada flag lain (R30-5)
      if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                                 and o.target_id = sub.id and o.status in ('open', 'held')) then
        update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
      end if;
    end if;
  end if;
  -- §12: setiap sanksi tercatat dan bisa dibanding sekali (trust.sanctions); ban fraud queue juga memblokir login identity
  if p_action <> 'dismiss' and target_user is not null then
    perform trust.record_sanction(target_user, p_action, f.id, p_note,
                                  case when p_action = 'suspend' then now() + interval '30 days' end, p_action = 'ban');
  end if;

  score_delta := case p_action when 'warn' then -5 when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $function$;

CREATE OR REPLACE FUNCTION trust.file_appeal (
  p_sanction uuid,
  p_user     uuid,
  p_message  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s trust.sanctions;
begin
  select * into s from trust.sanctions x where x.id = p_sanction and (p_user is null or x.user_id = p_user) for update;
  if not found then
    raise exception 'not_found:sanction' using errcode = 'P0002';
  end if;
  if s.appealed_at is not null then
    raise exception 'already_appealed' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_message, ''))) not between 10 and 1000 then
    raise exception 'invalid:message' using errcode = 'P0001';
  end if;
  update trust.sanctions set appeal_message = btrim(p_message), appealed_at = now() where id = s.id;
end $function$;

CREATE OR REPLACE FUNCTION trust.record_sanction (
  p_user          uuid,
  p_kind          text,
  p_flag          uuid,
  p_reason        text,
  p_until         timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_login_blocked boolean                  DEFAULT false
)
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  insert into trust.sanctions (user_id, kind, flag_id, reason, created_by, until, login_blocked)
  values (p_user, p_kind, p_flag, left(nullif(btrim(p_reason), ''), 500), (select auth.uid()), p_until, coalesce(p_login_blocked, false))
  returning id;
$function$;

CREATE VIEW "api"."sanctions" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    kind,
    flag_id,
    reason,
    created_at,
    until,
    lifted_at,
    appeal_message,
    appealed_at,
    decision,
    decision_note,
    decided_at
   FROM trust.sanctions;

REVOKE ALL ON FUNCTION "api"."record_sanction_appeal"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."record_sanction_appeal"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."record_sanction_appeal"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."record_sanction_appeal"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."file_appeal"(uuid, uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."file_appeal"(uuid, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."file_appeal"(uuid, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text, timestamp WITH time zone, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text, timestamp WITH time zone, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text, timestamp WITH time zone, boolean) TO "postgres";

GRANT SELECT ON TABLE "api"."sanctions" TO "authenticated";
