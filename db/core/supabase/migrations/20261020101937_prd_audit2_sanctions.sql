SET local check_function_bodies = off;

ALTER TABLE "trust"."score_events"
  DROP CONSTRAINT "score_events_reason_check";

CREATE TABLE "trust"."sanctions" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"        uuid                     NOT NULL,
  "kind"           text                     NOT NULL,
  "flag_id"        uuid,
  "reason"         text,
  "created_by"     uuid,
  "created_at"     timestamp with time zone NOT NULL DEFAULT now(),
  "appeal_message" text,
  "appealed_at"    timestamp with time zone,
  "decision"       text,
  "decision_note"  text,
  "decided_by"     uuid,
  "decided_at"     timestamp with time zone,
  CONSTRAINT "sanctions_appeal_complete" CHECK (((appealed_at IS NULL) = (appeal_message IS NULL))),
  CONSTRAINT "sanctions_appeal_message_check" CHECK (((length(appeal_message) >= 10) AND (length(appeal_message) <= 1000))),
  CONSTRAINT "sanctions_decision_check" CHECK ((decision = ANY (ARRAY['upheld'::text, 'overturned'::text]))),
  CONSTRAINT "sanctions_decision_complete" CHECK ((((decision IS NULL) = (decided_at IS NULL)) AND ((decision IS NULL) OR ((appealed_at IS NOT NULL) AND (decided_by IS
    NOT NULL))))),
  CONSTRAINT "sanctions_decision_note_check" CHECK (((length(decision_note) >= 3) AND (length(decision_note) <= 500))),
  CONSTRAINT "sanctions_kind_check" CHECK ((kind = ANY (ARRAY['warn'::text, 'hold'::text, 'reverse'::text, 'suspend'::text, 'ban'::text]))),
  CONSTRAINT "sanctions_pkey" PRIMARY KEY (id),
  CONSTRAINT "sanctions_reason_check" CHECK ((length(reason) <= 500))
);

ALTER TABLE "trust"."sanctions"
  ENABLE ROW LEVEL SECURITY;

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
  select * into s from trust.sanctions x where x.id = p_sanction and x.user_id = uid for update;
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
    if s.kind = 'suspend' then
      update market.profiles set status = 'active', suspended_until = null where id = s.user_id and status = 'suspended';
    elsif s.kind = 'ban' then
      update market.profiles set status = 'active', suspended_until = null where id = s.user_id and status = 'banned';
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', s.user_id, 'unban', true));
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
    perform trust.record_sanction(pr.id, 'suspend', null, prm ->> 'reason');
  elsif p_action = 'unsuspend' then
    if pr.status <> 'suspended' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id;
  elsif p_action = 'ban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'banned' where id = pr.id;
    -- Paritas dengan ban fraud queue (AA-7): pending hangus, tracking berhenti, payout ditahan, clipper dikabari.
    perform trust.apply_ban(pr.id, 'admin', jsonb_build_object('reason', prm ->> 'reason'));
    perform trust.record_sanction(pr.id, 'ban', null, prm ->> 'reason');
  elsif p_action = 'unban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id and status in ('banned', 'suspended');
  else
    perform market.fail('invalid:action', p_action);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'user.' || p_action, 'profile:' || pr.id,
          jsonb_build_object('status', pr.status, 'trust_score', pr.trust_score, 'suspended_until', pr.suspended_until),
          prm || jsonb_build_object('status', (select p.status from market.profiles p where p.id = pr.id),
                                    'trust_score', (select p.trust_score from market.profiles p where p.id = pr.id)));
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
end $function$;

CREATE OR REPLACE FUNCTION trust.record_sanction (
  p_user   uuid,
  p_kind   text,
  p_flag   uuid,
  p_reason text
)
  RETURNS uuid
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  insert into trust.sanctions (user_id, kind, flag_id, reason, created_by)
  values (p_user, p_kind, p_flag, left(nullif(btrim(p_reason), ''), 500), (select auth.uid()))
  returning id;
$function$;

ALTER TABLE "trust"."sanctions"
  ADD CONSTRAINT "sanctions_flag_id_fkey" FOREIGN KEY (flag_id) REFERENCES trust.fraud_flags(id);

ALTER TABLE "trust"."sanctions"
  ADD CONSTRAINT "sanctions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "trust"."score_events"
  ADD CONSTRAINT "score_events_reason_check"
    CHECK
    ((reason = ANY (ARRAY['submission_approved'::text, 'clean_tenure'::text, 'submission_rejected'::text, 'fraud_flag'::text, 'appeal_failed'::text, 'admin_override'::text,
    'appeal_overturned'::text])));

CREATE VIEW "api"."sanctions" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    kind,
    flag_id,
    reason,
    created_at,
    appeal_message,
    appealed_at,
    decision,
    decision_note,
    decided_at
   FROM trust.sanctions;

CREATE INDEX sanctions_appeal_queue_idx ON trust.sanctions USING btree (appealed_at)
  WHERE ((appealed_at IS NOT NULL) AND (decision IS NULL));

CREATE INDEX sanctions_flag_idx ON trust.sanctions USING btree (flag_id);

CREATE INDEX sanctions_user_idx ON trust.sanctions USING btree (user_id, created_at DESC);

CREATE POLICY "sanctions_admin_read" ON "trust"."sanctions"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_moderator'::text, 'admin_support'::text]) AS has_admin));

CREATE POLICY "sanctions_iss" ON "trust"."sanctions"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "sanctions_own_read" ON "trust"."sanctions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

REVOKE ALL ON FUNCTION "api"."appeal_sanction"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."appeal_sanction"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."appeal_sanction"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."appeal_sanction"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."decide_sanction_appeal"(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."decide_sanction_appeal"(uuid, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."decide_sanction_appeal"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."decide_sanction_appeal"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."record_sanction"(uuid, text, uuid, text) TO "postgres";

GRANT SELECT ON TABLE "trust"."sanctions" TO "authenticated";

GRANT SELECT ON TABLE "api"."sanctions" TO "authenticated";
