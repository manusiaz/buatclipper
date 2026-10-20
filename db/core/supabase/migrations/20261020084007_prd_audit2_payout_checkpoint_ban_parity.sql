SET local check_function_bodies = off;

DROP TRIGGER "payouts_state_machine" ON "finance"."payouts";

CREATE OR REPLACE FUNCTION api.bridge_get_batch (
  p_batch uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
begin
  select * into b from finance.payout_batches x where x.id = p_batch;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status not in ('approved', 'exported') then  -- exported: identity menandatangani ulang link berkas yang sama
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'batch', jsonb_build_object('id', b.id, 'status', b.status, 'created_by', b.created_by, 'approved_by', b.approved_by,
                                'file_ref', b.file_ref),
    -- blocked: profil di-ban/suspend atau flag fraud terbuka sejak batch disetujui → identity menahannya (bukan masuk CSV).
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id,
                                                             'amount', p.amount, 'fee', p.fee,
                                                             'blocked', finance.payout_block(p.user_id, p.id)) order by p.id)
                         from finance.payouts p where p.batch_id = b.id and p.status = 'requested'), '[]'));
end $function$;

CREATE OR REPLACE FUNCTION api.create_payout_batch (
  p_cutoff timestamp with time zone
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  bid uuid;
  n int;
  held int := 0;
  x record;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  -- Checkpoint §12: clipper yang di-ban/suspend atau ber-flag fraud terbuka tidak ikut ditransfer → ditahan dengan alasannya.
  for x in select p.id, finance.payout_block(p.user_id, p.id) reason from finance.payouts p
            where p.status = 'requested' and p.channel = 'batch' and p.batch_id is null and p.created_at <= coalesce(p_cutoff, now()) loop
    continue when x.reason is null;
    perform finance.hold_payouts(null, x.id, x.reason);
    held := held + 1;
  end loop;
  insert into finance.payout_batches (created_by, cutoff_at) values ((select auth.uid()), coalesce(p_cutoff, now()))
  returning id into bid;
  update finance.payouts set batch_id = bid
   where status = 'requested' and channel = 'batch' and batch_id is null and created_at <= coalesce(p_cutoff, now());
  get diagnostics n = row_count;
  if n = 0 and held = 0 then
    raise exception 'batch_empty' using errcode = 'P0001';
  elsif n = 0 then  -- semua ditahan: tahan tetap tersimpan, tanpa batch kosong
    delete from finance.payout_batches where id = bid;
    return null;
  end if;
  update finance.payout_batches b set count = n,
         total = (select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = bid)
   where b.id = bid;
  insert into ops.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'payout_batch.create', 'payout_batch:' || bid,
          (select jsonb_build_object('count', b.count, 'total', b.total, 'cutoff', p_cutoff) from finance.payout_batches b where b.id = bid));
  return bid;
end $function$;

CREATE OR REPLACE FUNCTION api.hold_payout (
  p_payout uuid,
  p_reason text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  if finance.hold_payouts(null, p_payout, btrim(p_reason)) = 0 then
    raise exception 'invalid_state:payout' using errcode = 'P0001',
      detail = 'hanya payout batch requested yang belum masuk batch disetujui';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.hold', 'payout:' || p_payout, jsonb_build_object('status', 'requested'),
          jsonb_build_object('status', 'on_hold', 'reason', btrim(p_reason)));
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

CREATE OR REPLACE FUNCTION api.release_payout (
  p_payout uuid,
  p_note   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
  blocked text;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status <> 'on_hold' or po.channel <> 'batch' then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  blocked := finance.payout_block(po.user_id, po.id);
  if blocked is not null then
    raise exception 'payout_blocked:%', blocked using errcode = 'P0001';
  end if;
  update finance.payouts set status = 'requested', hold_reason = null, batch_id = null where id = po.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.release', 'payout:' || po.id, jsonb_build_object('status', 'on_hold', 'reason', po.hold_reason),
          jsonb_build_object('status', 'requested', 'note', btrim(p_note)));
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
  if p_action is null or p_action not in ('hold', 'reverse', 'suspend', 'ban', 'dismiss') then
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
    end if;
  end if;

  score_delta := case p_action when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $function$;

CREATE OR REPLACE FUNCTION finance.hold_payouts (
  p_user   uuid,
  p_payout uuid,
  p_reason text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
begin
  update finance.payouts p set status = 'on_hold', hold_reason = p_reason, batch_id = null
   where p.status = 'requested' and p.channel = 'batch' and (p_user is null or p.user_id = p_user)
     and (p_payout is null or p.id = p_payout)
     and (p.batch_id is null or exists (select 1 from finance.payout_batches b where b.id = p.batch_id and b.status = 'draft'));
  get diagnostics n = row_count;
  update finance.payout_batches b
     set count = (select count(*) from finance.payouts p where p.batch_id = b.id),
         total = coalesce((select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = b.id), 0)
   where b.status = 'draft';
  return n;
end $function$;

CREATE OR REPLACE FUNCTION finance.payout_block (
  p_user   uuid,
  p_payout uuid
)
  RETURNS text
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select case
    when pr.id is null then 'profile_missing'
    when pr.status in ('banned', 'closed') then 'profile_' || pr.status
    when pr.status = 'suspended' and (pr.suspended_until is null or pr.suspended_until > now()) then 'profile_suspended'
    when exists (select 1 from trust.fraud_flags f
                  where f.status in ('open', 'held')
                    and ((f.target_type = 'profile' and f.target_id = p_user) or (f.target_type = 'payout' and f.target_id = p_payout)))
      then 'fraud_flag'
  end
  from (select 1) one left join market.profiles pr on pr.id = p_user;
$function$;

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
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  perform finance.hold_payouts(p_user, null, 'profile_banned');
  perform ops.enqueue_notification(p_user, 'account.banned', p_payload);
end $function$;

CREATE OR REPLACE FUNCTION trust.raise_flag (
  p_target_type text,
  p_target_id   uuid,
  p_signal      text,
  p_score       numeric,
  p_details     jsonb,
  p_status      text    DEFAULT 'open'::text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE TRIGGER payouts_state_machine
  BEFORE INSERT OR UPDATE OF status ON finance.payouts
  FOR EACH ROW
  EXECUTE FUNCTION
    ops.check_transition('S-05', 'requested',
    '{"requested":["on_hold","processing"],"on_hold":["processing","cancelled","requested"],"processing":["paid","failed"],"paid":["failed"],"failed":["requested","returned"]}');

REVOKE ALL ON FUNCTION "api"."hold_payout"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."hold_payout"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."hold_payout"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."hold_payout"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."release_payout"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."release_payout"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."release_payout"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."release_payout"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."hold_payouts"(uuid, uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."hold_payouts"(uuid, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."hold_payouts"(uuid, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."payout_block"(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."payout_block"(uuid, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."payout_block"(uuid, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."apply_ban"(uuid, text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."apply_ban"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."apply_ban"(uuid, text, jsonb) TO "postgres";
