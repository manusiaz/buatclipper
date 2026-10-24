SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION bus_in.submission_post_gone (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  perform tracking.post_gone((p ->> 'submission_id')::uuid, p ->> 'reason');
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', p ->> 'submission_id', 'step', 'post_gone',
                                                                               'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_submissions_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.decide_new_submission((p_row ->> 'id')::uuid);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', p_row ->> 'id', 'step', 'decide',
                                                                               'error', sqlerrm));
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_view_snapshots_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.apply_snapshot((p_row ->> 'id')::bigint);
  end if;
exception when others then
  perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('snapshot_id', p_row ->> 'id', 'step', 'snapshot',
                                                                               'error', sqlerrm));
end $function$;
