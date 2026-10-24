SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.skip_failed_snapshot (
  p_alert bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a ops.alerts;
  v tracking.view_snapshots;
  s tracking.submissions;
begin
  if not ops.has_admin('admin_ops') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into a from ops.alerts x where x.id = p_alert and x.kind = 'tracking.apply_failed' and x.resolved_at is null for update;
  if not found or coalesce(a.payload ->> 'snapshot_id', '') !~ '^[0-9]+$' then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  select * into v from tracking.view_snapshots x where x.id = (a.payload ->> 'snapshot_id')::bigint;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  if v.id is distinct from (select min(x.id) from tracking.view_snapshots x
                             where x.submission_id = s.id and x.id > coalesce(s.applied_snapshot_id, 0)) then
    raise exception 'invalid_state:not_next_pending' using errcode = 'P0001';
  end if;
  update tracking.submissions set applied_snapshot_id = v.id,
         status = case when status = 'tracking' then 'flagged'::tracking.submission_status else status end
   where id = s.id;
  perform trust.raise_flag('submission', s.id, 'FR-12', 50,
                           jsonb_build_object('snapshot_id', v.id, 'alert_id', a.id, 'error', a.payload ->> 'error'));
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = a.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'snapshot.skip', 'submission:' || s.id,
          jsonb_build_object('applied_snapshot_id', s.applied_snapshot_id, 'status', s.status),
          jsonb_build_object('applied_snapshot_id', v.id, 'alert_id', a.id));
end $function$;

CREATE OR REPLACE FUNCTION bus.skip (
  p_target text,
  p_seq    bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  o bus.outbox;
begin
  select * into o from bus.outbox x where x.target = p_target and x.sent_at is null order by x.seq limit 1 for update;
  if not found or o.seq <> p_seq then
    raise exception 'bus_skip:bukan kepala antrean % (kepala: %)', p_target, o.seq using errcode = 'P0001';
  end if;
  update bus.outbox set sent_at = now(), request_id = null, last_error = 'dilewati operator ' || now() || ': ' || coalesce(last_error, '')
   where seq = o.seq;
  return jsonb_build_object('seq', o.seq, 'topic', o.topic, 'payload', o.payload, 'attempts', o.attempts, 'last_error', o.last_error);
end $function$;

REVOKE ALL ON FUNCTION "api"."skip_failed_snapshot"(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."skip_failed_snapshot"(bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."skip_failed_snapshot"(bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."skip_failed_snapshot"(bigint) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."skip"(text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."skip"(text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."skip"(text, bigint) TO "postgres";
