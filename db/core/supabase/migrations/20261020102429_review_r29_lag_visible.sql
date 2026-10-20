SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION tracking.lagging_count()
  RETURNS integer
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return (select count(*)::int from (
            select s.id from tracking.submissions s
             where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours'
            union
            select s.id from pgmq.q_tracking q
              join tracking.submissions s on s.id::text = q.message ->> 'submission_id' and s.status in ('tracking', 'flagged')
             where q.enqueued_at < now() - interval '1 hour' and q.vt <= now()) x);
end $function$;
