CREATE VIEW "api"."settings" WITH (security_invoker=true) AS  SELECT key,
    value,
    updated_at
   FROM ops.settings;

GRANT SELECT ON TABLE "api"."settings" TO "anon", "authenticated";
