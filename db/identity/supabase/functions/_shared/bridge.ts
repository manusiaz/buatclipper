// Server-to-server bridge between identity and core (§15.5). One HMAC secret per direction:
//   BRIDGE_SECRET_IDENTITY_TO_CORE  identity signs outbound calls to core
//   BRIDGE_SECRET_CORE_TO_IDENTITY  identity verifies inbound calls from core
// Wire format: POST {TARGET}/functions/v1/bridge, headers x-bridge-ts (unix seconds) and
// x-bridge-sig = lowercase hex HMAC-SHA256(secret, ts + "." + rawBody), body {"v":1,"action":…,"payload":{…}}.
// Rejected: |now − ts| > 300 s, v ≠ 1, bad signature (constant-time compare).
// Response: {"ok":true,"data":…} or 4xx/5xx {"ok":false,"error":{"code","message"}}.
import { hmacSha256Hex, timingSafeEqual } from "./crypto.ts";
import { env, HttpError, log } from "./http.ts";

export const BRIDGE_MAX_SKEW_S = 300;

export async function signBridge(secret: string, ts: string, rawBody: string): Promise<string> {
  return await hmacSha256Hex(secret, `${ts}.${rawBody}`);
}

export interface BridgeMessage {
  action: string;
  payload: Record<string, unknown>;
}

export async function verifyBridge(opts: {
  secret: string;
  ts: string | null;
  sig: string | null;
  rawBody: string;
  nowS?: number;
}): Promise<BridgeMessage> {
  const nowS = opts.nowS ?? Math.floor(Date.now() / 1000);
  if (!opts.ts || !/^\d{1,12}$/.test(opts.ts)) throw new HttpError(401, "bad_timestamp", "x-bridge-ts tidak valid");
  if (Math.abs(nowS - Number(opts.ts)) > BRIDGE_MAX_SKEW_S) {
    throw new HttpError(401, "stale_request", "permintaan kedaluwarsa");
  }
  if (!opts.sig || !/^[0-9a-f]{64}$/.test(opts.sig)) {
    throw new HttpError(401, "bad_signature", "tanda tangan tidak valid");
  }
  const expected = await signBridge(opts.secret, opts.ts, opts.rawBody);
  if (!timingSafeEqual(expected, opts.sig)) throw new HttpError(401, "bad_signature", "tanda tangan tidak valid");

  let body: unknown;
  try {
    body = JSON.parse(opts.rawBody);
  } catch {
    throw new HttpError(400, "invalid_json", "body bukan JSON");
  }
  const b = body as Record<string, unknown> | null;
  if (!b || typeof b !== "object" || b.v !== 1) throw new HttpError(400, "unsupported_version", "v harus 1");
  if (typeof b.action !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(b.action)) {
    throw new HttpError(400, "invalid_action", "action tidak valid");
  }
  const payload = b.payload ?? {};
  if (typeof payload !== "object" || Array.isArray(payload) || payload === null) {
    throw new HttpError(400, "invalid_payload", "payload harus objek");
  }
  return { action: b.action, payload: payload as Record<string, unknown> };
}

/** Error returned by the other side of the bridge (or transport failure). */
export class BridgeError extends HttpError {
  constructor(public remoteStatus: number, code: string, message: string) {
    // Remote business refusal (400/404/409/422…) keeps its status; 401/403 means our signature/secret is wrong and
    // 5xx/transport is an upstream failure — both are 502 for our caller.
    super(
      remoteStatus >= 400 && remoteStatus < 500 && remoteStatus !== 401 && remoteStatus !== 403 ? remoteStatus : 502,
      code,
      message,
    );
    this.name = "BridgeError";
  }
}

export interface CoreBridge {
  invoke<T = unknown>(action: string, payload: Record<string, unknown>): Promise<T>;
}

/** CORE_FUNCTIONS_URL may be the project URL or the …/functions/v1 base; both resolve to …/functions/v1/bridge. */
export function bridgeUrl(base: string): string {
  const b = base.replace(/\/+$/, "");
  return b.endsWith("/functions/v1") ? `${b}/bridge` : `${b}/functions/v1/bridge`;
}

export function createCoreBridge(opts: {
  url: string;
  secret: string;
  fetchFn?: typeof fetch;
  attempts?: number;
  timeoutMs?: number;
}): CoreBridge {
  const fetchFn = opts.fetchFn ?? fetch;
  const attempts = opts.attempts ?? 3;
  const timeoutMs = opts.timeoutMs ?? 15_000;
  return {
    async invoke<T>(action: string, payload: Record<string, unknown>): Promise<T> {
      const rawBody = JSON.stringify({ v: 1, action, payload });
      let lastErr: BridgeError | undefined;
      for (let i = 0; i < attempts; i++) {
        if (i > 0) await new Promise((r) => setTimeout(r, 250 * 2 ** (i - 1)));
        const ts = String(Math.floor(Date.now() / 1000));
        const sig = await signBridge(opts.secret, ts, rawBody);
        let res: Response;
        try {
          res = await fetchFn(opts.url, {
            method: "POST",
            headers: { "content-type": "application/json", "x-bridge-ts": ts, "x-bridge-sig": sig },
            body: rawBody,
            signal: AbortSignal.timeout(timeoutMs),
          });
        } catch {
          lastErr = new BridgeError(503, "core_unreachable", `bridge core ${action} tidak bisa dihubungi`);
          continue; // every bridge action is idempotent (§15.5), retry is safe
        }
        let parsed: { ok?: boolean; data?: T; error?: { code?: string; message?: string } } = {};
        try {
          parsed = await res.json();
        } catch {
          // non-JSON response
        }
        if (res.ok && parsed.ok === true) return parsed.data as T;
        const code = typeof parsed.error?.code === "string" ? parsed.error.code : `core_http_${res.status}`;
        const message = typeof parsed.error?.message === "string"
          ? parsed.error.message
          : `bridge core ${action} gagal`;
        lastErr = new BridgeError(res.status, code, message);
        if (res.status < 500 && res.status !== 429) break; // refusal, not transient
      }
      log("warn", { fn: "bridge-out", action, code: lastErr?.code, status: lastErr?.remoteStatus });
      throw lastErr!;
    },
  };
}

let cachedCore: CoreBridge | undefined;
export function coreBridge(): CoreBridge {
  cachedCore ??= createCoreBridge({
    url: bridgeUrl(env("CORE_FUNCTIONS_URL")),
    secret: env("BRIDGE_SECRET_IDENTITY_TO_CORE"),
  });
  return cachedCore;
}
