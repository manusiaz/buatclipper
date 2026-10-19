// Instant withdraw (alur 11, F-C15, D-15). Core request_payout(channel instant) already moved the money in the ledger;
// identity re-checks the method owner + KYC name (same rules as the batch CSV), decrypts the account number, sends it
// to the disbursement provider with idempotency key = payout id, and reports back through core mark_instant.
// Provider webhooks land on POST /disburse/callback and are mapped to paid / failed.
//
// Xendit Payouts API v2 (verified against xendit-node 7.0.0 generated client, payout/apis/Payout.js + models):
//   POST https://api.xendit.co/v2/payouts, Authorization: Basic base64(<secret key>:), header idempotency-key (required)
//   body {reference_id, channel_code, channel_properties:{account_number, account_holder_name}, amount, currency,
//         description}; response = payout {id ("disb-…"), reference_id, status, failure_code, …}
//   status ∈ ACCEPTED, REQUESTED, LOCKED, SUCCEEDED, FAILED, CANCELLED, REVERSED.
//   Webhook: header x-callback-token (verification token from the dashboard); body {event:"payout.succeeded" |
//   "payout.failed" | "payout.reversed", business_id, created, data:{id, reference_id, status, failure_code, …}}.
//   Retried for 24 h until we answer 2xx.
import type { CoreBridge } from "./bridge.ts";
import { type PiiCrypto, timingSafeEqual } from "./crypto.ts";
import type { Rpc } from "./db.ts";
import { env, envOpt, HttpError, isUuid, log } from "./http.ts";
import { formatCents, holdReason, type KycRow, type MethodRow, toCents } from "./payouts.ts";

export type InstantStatus = "processing" | "paid" | "failed";

export interface DisburseRequest {
  payoutId: string;
  kind: "bank" | "ewallet";
  bankCode: string;
  accountNo: string;
  accountName: string;
  /** Integer rupiah as a decimal string (amount − fee). */
  amountIdr: string;
  description: string;
}

export interface DisburseResult {
  providerRef: string;
  status: InstantStatus;
  error?: string | null;
}

export interface CallbackResult {
  payoutId: string;
  providerRef: string | null;
  status: "paid" | "failed";
  error: string | null;
}

/** Provider refused the request for good (bad destination, unsupported channel): the payout fails, saldo returns. */
export class ProviderRejected extends Error {
  constructor(public code: string) {
    super(code);
    this.name = "ProviderRejected";
  }
}

export interface DisbursementProvider {
  readonly name: string;
  send(req: DisburseRequest): Promise<DisburseResult>;
  /** Maps a verified webhook body; null = event we do not act on (still answered 200). */
  parseCallback(body: unknown): CallbackResult | null;
}

export function mapXenditStatus(status: unknown): InstantStatus | null {
  switch (status) {
    case "SUCCEEDED":
      return "paid";
    case "FAILED":
    case "REVERSED":
    case "CANCELLED":
      return "failed";
    case "ACCEPTED":
    case "REQUESTED":
    case "LOCKED":
      return "processing";
    default:
      return null;
  }
}

/** Our bank_code ("BCA", "OVO") → Xendit channel code ("ID_BCA", "ID_OVO"). Codes already prefixed pass through. */
export function xenditChannelCode(bankCode: string): string {
  return bankCode.startsWith("ID_") ? bankCode : `ID_${bankCode}`;
}

interface XenditPayout {
  id?: string;
  reference_id?: string;
  status?: string;
  failure_code?: string | null;
  error_code?: string;
}

export class XenditProvider implements DisbursementProvider {
  readonly name = "xendit";
  constructor(
    private secretKey: string,
    private fetchFn: typeof fetch = fetch,
    private baseUrl = "https://api.xendit.co",
  ) {}

  #headers(extra: Record<string, string> = {}): Record<string, string> {
    return { authorization: "Basic " + btoa(`${this.secretKey}:`), "content-type": "application/json", ...extra };
  }

  async #request(
    path: string,
    init: RequestInit,
  ): Promise<{ status: number; body: XenditPayout & { data?: XenditPayout[] } }> {
    let res: Response;
    try {
      res = await this.fetchFn(`${this.baseUrl}${path}`, { ...init, signal: AbortSignal.timeout(20_000) });
    } catch {
      throw new HttpError(503, "provider_unavailable", "penyedia disbursement tidak bisa dihubungi");
    }
    const body = await res.json().catch(() => ({}));
    return { status: res.status, body };
  }

  #result(p: XenditPayout): DisburseResult {
    const status = mapXenditStatus(p.status);
    if (!p.id || !status) throw new HttpError(502, "provider_bad_response", "respons penyedia tidak dikenal");
    return { providerRef: p.id, status, error: status === "failed" ? (p.failure_code ?? p.status ?? null) : null };
  }

  async send(req: DisburseRequest): Promise<DisburseResult> {
    const { status, body } = await this.#request("/v2/payouts", {
      method: "POST",
      headers: this.#headers({ "idempotency-key": req.payoutId }),
      body: JSON.stringify({
        reference_id: req.payoutId,
        channel_code: xenditChannelCode(req.bankCode),
        channel_properties: { account_number: req.accountNo, account_holder_name: req.accountName },
        amount: Number(req.amountIdr),
        currency: "IDR",
        description: req.description,
      }),
    });
    if (status >= 200 && status < 300) return this.#result(body);
    if (status === 409) {
      // Same idempotency key seen before (e.g. our earlier attempt timed out): read the payout we already created.
      const found = await this.#request(`/v2/payouts?reference_id=${encodeURIComponent(req.payoutId)}`, {
        method: "GET",
        headers: this.#headers(),
      });
      const first = Array.isArray(found.body.data)
        ? found.body.data[0]
        : Array.isArray(found.body)
        ? (found.body as XenditPayout[])[0]
        : undefined;
      if (found.status === 200 && first) return this.#result(first);
      throw new HttpError(503, "provider_unavailable", "status payout di penyedia belum bisa dibaca");
    }
    if (status === 401 || status === 403) {
      // Our key or permissions are wrong: leave the payout untouched so finance sees it hanging (J-A3 A3.7).
      throw new HttpError(502, "provider_auth", "kredensial penyedia disbursement ditolak");
    }
    if (status === 429 || status >= 500) throw new HttpError(503, "provider_unavailable", "penyedia sedang sibuk");
    throw new ProviderRejected(typeof body.error_code === "string" ? body.error_code : `HTTP_${status}`);
  }

  parseCallback(body: unknown): CallbackResult | null {
    const b = body as { event?: unknown; data?: XenditPayout } & XenditPayout;
    const d: XenditPayout = b && typeof b === "object" && b.data && typeof b.data === "object" ? b.data : b;
    if (!d || !isUuid(d.reference_id)) return null;
    let status = mapXenditStatus(d.status);
    if (!status && typeof b.event === "string") {
      status = b.event === "payout.succeeded"
        ? "paid"
        : b.event === "payout.failed" || b.event === "payout.reversed"
        ? "failed"
        : null;
    }
    if (status !== "paid" && status !== "failed") return null;
    return {
      payoutId: d.reference_id!.toLowerCase(),
      providerRef: typeof d.id === "string" ? d.id : null,
      status,
      error: status === "failed" ? (d.failure_code ?? d.status ?? "FAILED") : null,
    };
  }
}

/** Local development only: succeeds immediately without moving money. */
export class MockProvider implements DisbursementProvider {
  readonly name = "mock";
  send(req: DisburseRequest): Promise<DisburseResult> {
    return Promise.resolve({ providerRef: `mock-${req.payoutId}`, status: "paid" });
  }
  parseCallback(): CallbackResult | null {
    return null;
  }
}

export function isLocalUrl(raw: string | undefined): boolean {
  try {
    const h = new URL(raw ?? "").hostname;
    return ["localhost", "127.0.0.1", "kong", "host.docker.internal"].includes(h) || h.startsWith("supabase_kong_");
  } catch {
    return false;
  }
}

export function providerFromEnv(): DisbursementProvider {
  const name = envOpt("DISBURSE_PROVIDER") ?? "xendit";
  if (name === "xendit") return new XenditProvider(env("XENDIT_SECRET_KEY"));
  if (name === "mock") {
    if (!isLocalUrl(envOpt("SUPABASE_URL"))) {
      throw new HttpError(500, "config_invalid", "provider mock hanya untuk stack lokal");
    }
    return new MockProvider();
  }
  throw new HttpError(500, "config_invalid", "DISBURSE_PROVIDER tidak dikenal");
}

// ---- flow ----------------------------------------------------------------------------------------------------------

interface CorePayout {
  id: string;
  user_id: string;
  method_id: string;
  amount: string | number;
  fee: string | number;
  channel: string;
  status: string;
}

export interface DisburseDeps {
  core: () => CoreBridge;
  rpc: Rpc;
  crypto: () => PiiCrypto;
  provider: () => DisbursementProvider;
}

async function markInstant(
  core: CoreBridge,
  payoutId: string,
  status: InstantStatus,
  providerRef: string | null,
  error: string | null,
): Promise<void> {
  await core.invoke("mark_instant", { payout_id: payoutId, status, provider_ref: providerRef, error });
}

export async function runDisburse(
  deps: DisburseDeps,
  payoutId: string,
): Promise<
  { payout_id: string; status: string; provider_ref?: string | null; error?: string | null; skipped?: boolean }
> {
  const core = deps.core();
  const p = await core.invoke<CorePayout>("get_payout", { payout_id: payoutId });
  if (!p || p.id !== payoutId) throw new HttpError(404, "payout_not_found", "payout tidak ditemukan");
  if (p.channel !== "instant") throw new HttpError(409, "not_instant", "payout bukan instant");
  if (p.status !== "requested" && p.status !== "processing") {
    return { payout_id: payoutId, status: p.status, skipped: true }; // already settled: idempotent no-op
  }

  const [method] = await deps.rpc.invoke<MethodRow[]>("svc_payout_methods", { p_ids: [p.method_id] }) ?? [];
  const [kyc] = await deps.rpc.invoke<KycRow[]>("svc_kyc", { p_user_ids: [p.user_id] }) ?? [];
  let reason: string | null = holdReason(p, method, kyc);
  let net = 0n;
  if (!reason) {
    try {
      net = toCents(p.amount) - toCents(p.fee);
    } catch {
      reason = "invalid_amount";
    }
    if (!reason && (net <= 0n || net % 100n !== 0n)) reason = "invalid_amount"; // IDR transfers are whole rupiah
  }
  if (reason) {
    await markInstant(core, payoutId, "failed", null, reason);
    return { payout_id: payoutId, status: "failed", error: reason };
  }

  const accountNo = await deps.crypto().decryptPg(
    "payout.account_no",
    method!.account_no_enc!,
    method!.enc_key_version!,
  );
  const provider = deps.provider();
  let result: DisburseResult;
  try {
    result = await provider.send({
      payoutId,
      kind: method!.kind,
      bankCode: method!.bank_code,
      accountNo,
      accountName: method!.account_name!,
      amountIdr: formatCents(net).replace(/\.00$/, ""),
      description: `Clipper payout ${payoutId.slice(0, 8)}`,
    });
  } catch (err) {
    if (err instanceof ProviderRejected) {
      await markInstant(core, payoutId, "failed", null, err.code);
      return { payout_id: payoutId, status: "failed", error: err.code };
    }
    throw err; // transient: core retries the bridge call, the idempotency key prevents a double transfer
  }

  await markInstant(core, payoutId, "processing", result.providerRef, null);
  if (result.status !== "processing") {
    await markInstant(core, payoutId, result.status, result.providerRef, result.error ?? null);
  }
  log("info", { fn: "disburse", provider: provider.name, payout_id: payoutId, status: result.status });
  return { payout_id: payoutId, status: result.status, provider_ref: result.providerRef, error: result.error ?? null };
}

/** Provider webhook. Token compared in constant time; core failure → 502 so the provider retries. */
export async function handleCallback(
  deps: { core: () => CoreBridge; provider: () => DisbursementProvider; token: () => string },
  headers: Headers,
  rawBody: string,
): Promise<{ ignored: boolean; payout_id?: string; status?: string }> {
  const got = headers.get("x-callback-token") ?? "";
  if (!got || !timingSafeEqual(got, deps.token())) {
    throw new HttpError(401, "bad_callback_token", "token callback salah");
  }
  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    throw new HttpError(400, "invalid_json", "body bukan JSON");
  }
  const cb = deps.provider().parseCallback(body);
  if (!cb) return { ignored: true };
  await markInstant(deps.core(), cb.payoutId, cb.status, cb.providerRef, cb.error);
  return { ignored: false, payout_id: cb.payoutId, status: cb.status };
}
