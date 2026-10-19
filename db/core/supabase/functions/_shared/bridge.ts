// Protokol bridge antar-project (PRD §15.5), identik di identity:
//   POST {TARGET}/functions/v1/bridge
//   x-bridge-ts:  detik unix
//   x-bridge-sig: hex HMAC-SHA256(secret, ts + "." + rawBody)
//   body {"v":1,"action":"…","payload":{…}}  →  {"ok":true,"data":…} | 4xx/5xx {"ok":false,"error":{code,message}}
// Ditolak kalau |now − ts| > 300 detik, v ≠ 1, atau tanda tangan salah (perbandingan waktu-konstan).
import { env, hmacHex, HttpError, safeEqual } from "./http.ts";

export const BRIDGE_MAX_SKEW_S = 300;

export interface BridgeMessage {
  v: 1;
  action: string;
  payload: Record<string, unknown>;
}

export function signBridge(secret: string, ts: number | string, rawBody: string): Promise<string> {
  return hmacHex(secret, `${ts}.${rawBody}`);
}

/** Verifikasi request masuk; mengembalikan pesan yang sudah di-parse. Body dibaca sekali sebagai teks mentah. */
export async function verifyBridge(
  req: Request,
  secret: string,
  nowS = Math.floor(Date.now() / 1000),
): Promise<BridgeMessage> {
  const ts = req.headers.get("x-bridge-ts") ?? "";
  const sig = (req.headers.get("x-bridge-sig") ?? "").toLowerCase();
  const raw = await req.text();
  if (!/^\d{1,12}$/.test(ts) || !/^[0-9a-f]{64}$/.test(sig)) throw new HttpError(401, "bad_signature");
  if (Math.abs(nowS - Number(ts)) > BRIDGE_MAX_SKEW_S) throw new HttpError(401, "expired");
  if (!(await safeEqual(sig, await signBridge(secret, ts, raw)))) throw new HttpError(401, "bad_signature");
  let msg: BridgeMessage;
  try {
    msg = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "bad_json");
  }
  if (msg?.v !== 1) throw new HttpError(400, "bad_version");
  if (typeof msg.action !== "string" || !msg.action) throw new HttpError(400, "bad_action");
  if (msg.payload === undefined) msg.payload = {};
  if (typeof msg.payload !== "object" || msg.payload === null || Array.isArray(msg.payload)) {
    throw new HttpError(400, "bad_payload");
  }
  return msg;
}

export class BridgeError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
  /** 4xx dari identity = permanen (mis. user sudah dihapus); 5xx/jaringan = boleh dicoba lagi. */
  get permanent(): boolean {
    return this.status >= 400 && this.status < 500 && this.status !== 408 && this.status !== 429;
  }
}

export interface BridgeTarget {
  url: string; // .../functions/v1
  secret: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export function identityTarget(): BridgeTarget {
  return { url: env("IDENTITY_FUNCTIONS_URL"), secret: env("BRIDGE_SECRET_CORE_TO_IDENTITY") };
}

export async function callBridge<T = unknown>(
  target: BridgeTarget,
  action: string,
  payload: Record<string, unknown>,
): Promise<T> {
  const body = JSON.stringify({ v: 1, action, payload });
  const ts = Math.floor(Date.now() / 1000);
  const sig = await signBridge(target.secret, ts, body);
  let res: Response;
  try {
    res = await (target.fetch ?? fetch)(`${target.url.replace(/\/+$/, "")}/bridge`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-bridge-ts": String(ts), "x-bridge-sig": sig },
      body,
      signal: AbortSignal.timeout(target.timeoutMs ?? 15_000),
    });
  } catch (e) {
    throw new BridgeError(503, "unreachable", e instanceof Error ? e.message : String(e));
  }
  let out: { ok?: boolean; data?: T; error?: { code?: string; message?: string } } = {};
  try {
    out = await res.json();
  } catch {
    // respons bukan JSON
  }
  if (!res.ok || out.ok !== true) {
    throw new BridgeError(
      res.ok ? 502 : res.status,
      out.error?.code ?? `http_${res.status}`,
      out.error?.message ?? res.statusText,
    );
  }
  return out.data as T;
}
