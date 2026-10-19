DROP VIEW "api"."invoices";

DROP VIEW "api"."org_refunds";

CREATE VIEW "api"."invoices" WITH (security_invoker=true) AS  SELECT id,
    number,
    org_id,
    campaign_id,
    kind,
    subtotal,
    mgmt_fee,
    admin_fee,
    service_fee,
    tax,
    total,
    status,
    payment_channel,
    paid_amount,
    paid_at,
    faktur_no,
    issued_at,
    due_at,
    pin_until,
    pool_topups,
    credit_applied,
    (total - credit_applied) AS amount_due
   FROM finance.invoices;

CREATE VIEW "api"."org_refunds" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    campaign_id,
    amount,
    transfer_fee,
    status,
    requested_by,
    created_at,
    paid_at
   FROM finance.org_refunds;

GRANT SELECT ON TABLE "api"."invoices" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_refunds" TO "authenticated";
