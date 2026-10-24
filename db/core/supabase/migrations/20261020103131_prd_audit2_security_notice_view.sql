DROP VIEW "api"."broadcasts";

CREATE VIEW "api"."broadcasts" WITH (security_invoker=true) AS  SELECT id,
    title,
    body,
    segment,
    channels,
    created_by,
    scheduled_at,
    sent_at,
    recipient_count,
    kind
   FROM ops.broadcasts;

GRANT SELECT ON TABLE "api"."broadcasts" TO "authenticated";
