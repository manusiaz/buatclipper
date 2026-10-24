CREATE POLICY "fee_rules_public_global" ON "finance"."fee_rules"
  FOR SELECT
  TO "anon"
  USING ((scope = 'global'::text));

REVOKE ALL ("admin_fee_pct") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("admin_fee_pct") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ("clipper_fee_pct") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("clipper_fee_pct") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ("id") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("id") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ("instant_withdraw_fee") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("instant_withdraw_fee") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ("mgmt_fee_pct") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("mgmt_fee_pct") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ("scope") ON TABLE "finance"."fee_rules" FROM "anon";

GRANT SELECT ("scope") ON TABLE "finance"."fee_rules" TO "anon";

REVOKE ALL ON TABLE "api"."fee_rules" FROM "anon";

GRANT SELECT ON TABLE "api"."fee_rules" TO "anon";
