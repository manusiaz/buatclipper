SET local check_function_bodies = off;

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

REVOKE ALL ON FUNCTION "bus"."skip"(text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."skip"(text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."skip"(text, bigint) TO "postgres";
