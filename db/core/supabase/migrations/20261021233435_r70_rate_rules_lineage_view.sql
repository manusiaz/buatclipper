DROP VIEW "api"."rate_rules";

CREATE VIEW "api"."rate_rules" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    kind,
    reward_type_id,
    pool_id,
    platform,
    params,
    effective_from,
    effective_to,
    lineage_id
   FROM market.rate_rules;

GRANT SELECT ON TABLE "api"."rate_rules" TO "anon", "authenticated";
