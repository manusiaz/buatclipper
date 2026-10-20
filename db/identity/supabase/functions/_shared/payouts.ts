// Payout eligibility re-checked in identity before any account number is decrypted (alur 3 batch CSV, alur 11 instant):
// the method must belong to the payout's user and be usable, the user's KYC must be approved, and the account name must
// equal the KYC legal name (same normalization as api.store_payout_method: trim, collapse spaces, lower case).
import { HttpError } from "./http.ts";

export type HoldReason =
  | "method_missing"
  | "method_owner_mismatch"
  | "method_disabled"
  | "kyc_not_approved"
  | "name_mismatch"
  | "invalid_amount"
  | "profile_blocked";

export interface MethodRow {
  id: string;
  user_id: string | null;
  kind: "bank" | "ewallet";
  bank_code: string;
  account_no_enc: string | null;
  account_last4: string | null;
  enc_key_version: number | null;
  account_name: string | null;
  disabled_at: string | null;
  blocked: boolean;
}

export interface KycRow {
  user_id: string;
  legal_name: string | null;
  nik_enc: string | null;
  enc_key_version: number | null;
  status: "pending" | "approved" | "rejected";
  closed: boolean;
}

export interface PayoutRef {
  id: string;
  user_id: string;
  method_id: string;
  amount: string | number;
  /** Biaya (gross − fee = yang ditransfer). Batch mingguan gratis → 0; ada untuk berjaga kalau batch berbiaya. */
  fee?: string | number;
  /** Alasan blokir dari core (finance.payout_block: ban/suspend/flag fraud terbuka); ada = tidak masuk CSV. */
  blocked?: string | null;
}

/** Jumlah yang benar-benar ditransfer ke rekening. */
export const netAmount = (p: PayoutRef): string => formatCents(toCents(p.amount) - toCents(p.fee ?? 0));

export function normalizeName(s: string | null | undefined): string {
  return (s ?? "").trim().replace(/\s+/g, " ").toLowerCase();
}

/** Money as integer cents (numeric(18,2) from core arrives as JSON number or string). */
export function toCents(v: unknown): bigint {
  const s = typeof v === "number" ? v.toFixed(2) : typeof v === "string" ? v.trim() : "";
  const m = /^(\d{1,16})(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) throw new HttpError(422, "invalid_amount", "jumlah tidak valid");
  return BigInt(m[1]) * 100n + BigInt((m[2] ?? "").padEnd(2, "0"));
}

export function formatCents(c: bigint): string {
  const neg = c < 0n;
  const a = neg ? -c : c;
  return `${neg ? "-" : ""}${a / 100n}.${(a % 100n).toString().padStart(2, "0")}`;
}

export function holdReason(p: PayoutRef, method: MethodRow | undefined, kyc: KycRow | undefined): HoldReason | null {
  if (p.blocked) return "profile_blocked";
  if (!method) return "method_missing";
  if (method.user_id !== p.user_id) return "method_owner_mismatch"; // includes tombstones (user_id NULL)
  if (method.disabled_at !== null || method.blocked) return "method_disabled";
  if (!method.account_no_enc || method.enc_key_version === null) return "method_missing";
  if (!kyc || kyc.closed || kyc.status !== "approved" || !kyc.legal_name) return "kyc_not_approved";
  if (normalizeName(method.account_name) !== normalizeName(kyc.legal_name)) return "name_mismatch";
  try {
    if (toCents(p.amount) - toCents(p.fee ?? 0) <= 0n) return "invalid_amount";
  } catch {
    return "invalid_amount";
  }
  return null;
}
