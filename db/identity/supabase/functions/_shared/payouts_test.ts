import { assertEquals } from "@std/assert";
import { holdReason, netAmount, type PayoutRef } from "./payouts.ts";

const p = (amount: string | number, fee?: string | number): PayoutRef => ({
  id: "p",
  user_id: "u",
  method_id: "m",
  amount,
  fee,
});

Deno.test("netAmount: CSV transfer = gross − fee; tanpa fee = gross", () => {
  assertEquals(netAmount(p("100000.00", "2500")), "97500.00");
  assertEquals(netAmount(p(150000)), "150000.00");
});

Deno.test("holdReason: fee ≥ amount → invalid_amount", () => {
  const method = {
    id: "m",
    user_id: "u",
    kind: "bank",
    bank_code: "BCA",
    account_no_enc: "\\x00",
    account_last4: "1234",
    enc_key_version: 1,
    account_name: "Andi",
    disabled_at: null,
    blocked: false,
  };
  const kyc = {
    user_id: "u",
    legal_name: "andi",
    nik_enc: null,
    enc_key_version: 1,
    status: "approved",
    closed: false,
  };
  // deno-lint-ignore no-explicit-any
  assertEquals(holdReason(p("5000", "5000"), method as any, kyc as any), "invalid_amount");
  // deno-lint-ignore no-explicit-any
  assertEquals(holdReason(p("5000", "0"), method as any, kyc as any), null);
  // AA-1: core menandai payout clipper yang di-ban/suspend/ber-flag → tidak masuk CSV walau rekening & KYC lolos
  const banned = { ...p("5000", "0"), blocked: "profile_banned" };
  // deno-lint-ignore no-explicit-any
  assertEquals(holdReason(banned, method as any, kyc as any), "profile_blocked");
});
