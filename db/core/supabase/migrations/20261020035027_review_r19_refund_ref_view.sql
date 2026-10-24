DROP VIEW "api"."org_refunds";

CREATE VIEW "api"."org_refunds" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    campaign_id,
    amount,
    transfer_fee,
    status,
    requested_by,
    created_at,
    paid_at,
    bank_ref
   FROM finance.org_refunds;

GRANT SELECT ON TABLE "api"."org_refunds" TO "authenticated";
