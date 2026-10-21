// Live Activity iOS payout lewat APNs langsung (Expo Push API tidak mengirim apns-push-type liveactivity). Token-based
// auth: JWT ES256 provider dari kunci APNs .p8 (Apple Developer → Keys), di-cache 50 menit per isolate (APNs menolak
// token > 1 jam). Env: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (PEM PKCS#8 isi .p8; "\n" literal diterima untuk env
// satu baris), APNS_BUNDLE_ID, APNS_ENV (sandbox = api.sandbox.push.apple.com). Env belum lengkap = fitur mati, tanpa error.
// Tipe ActivityKit app (expo-widgets) = LiveActivityAttributes: attributes {url}, ContentState {name, props: JSON string}.
//   payout.processing                              → event start (push-to-start) ke token apns_start user
//   payout.paid | payout.failed | payout.cancelled → event end ke token apns_activity (activity_ref = payout_id), lalu
//                                                    baris token dihapus (activity selesai)
// 410 / 400 BadDeviceToken = token mati → dihapus. Token & nomor rekening tidak pernah dikirim ke log; props hanya
// membawa bank_code + 4 digit terakhir.
import { b64decode, b64encode } from "./crypto.ts";
import type { Rpc } from "./db.ts";
import { log } from "./http.ts";
import type { PushResult, PushSubscriptionRow } from "./push.ts";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  privateKey: string;
  bundleId: string;
  sandbox: boolean;
}

export function apnsConfig(get: (n: string) => string | undefined = (n) => Deno.env.get(n)): ApnsConfig | null {
  const [keyId, teamId, privateKey, bundleId] = ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY", "APNS_BUNDLE_ID"]
    .map((n) => get(n)?.trim() ?? "");
  if (!keyId || !teamId || !privateKey || !bundleId) return null;
  return { keyId, teamId, privateKey, bundleId, sandbox: get("APNS_ENV")?.trim() === "sandbox" };
}

const te = new TextEncoder();
const b64url = (u: Uint8Array) => b64encode(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlJson = (o: unknown) => b64url(te.encode(JSON.stringify(o)));

/** DER PKCS#8 dari isi .p8: header/footer & spasi dibuang, "\n" literal (env satu baris) diterima. */
export function pemBody(pem: string): Uint8Array {
  return b64decode(pem.replace(/\\n/g, "\n").replace(/-----(BEGIN|END) [A-Z ]+-----/g, "").replace(/\s+/g, ""));
}

export async function importApnsKey(pem: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "pkcs8",
    pemBody(pem) as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    [
      "sign",
    ],
  );
}

/** JWT provider APNs: header {alg ES256, kid}, klaim {iss: team id, iat}; tanda tangan ECDSA P-256 r||s (format JOSE). */
export async function providerJwt(
  cfg: Pick<ApnsConfig, "keyId" | "teamId">,
  key: CryptoKey,
  iat: number,
): Promise<string> {
  const input = `${b64urlJson({ alg: "ES256", kid: cfg.keyId })}.${b64urlJson({ iss: cfg.teamId, iat })}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, te.encode(input)));
  return `${input}.${b64url(sig)}`;
}

export const PROVIDER_TOKEN_TTL_S = 50 * 60;

export interface ApnsResult {
  ok: boolean;
  /** 0 = jaringan / kunci provider bermasalah. */
  status: number;
  reason?: string;
  /** Token tidak berlaku lagi (410, atau 400 BadDeviceToken) → hapus. */
  dead: boolean;
}

export interface ApnsSender {
  send(token: string, payload: unknown): Promise<ApnsResult>;
}

export function apnsSender(
  cfg: ApnsConfig,
  opts: { fetchFn?: typeof fetch; nowS?: () => number } = {},
): ApnsSender {
  const fetchFn = opts.fetchFn ?? fetch;
  const nowS = opts.nowS ?? (() => Math.floor(Date.now() / 1000));
  const host = cfg.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  let key: Promise<CryptoKey> | undefined;
  let cached: { jwt: string; iat: number } | undefined;
  const bearer = async (): Promise<string> => {
    const now = nowS();
    if (!cached || now - cached.iat >= PROVIDER_TOKEN_TTL_S) {
      key ??= importApnsKey(cfg.privateKey);
      cached = { jwt: await providerJwt(cfg, await key, now), iat: now };
    }
    return cached.jwt;
  };
  return {
    async send(token, payload) {
      if (!/^[0-9a-f]{32,}$/.test(token)) return { ok: false, status: 400, reason: "BadDeviceToken", dead: true };
      let auth: string;
      try {
        auth = await bearer();
      } catch {
        key = undefined;
        return { ok: false, status: 0, reason: "provider_key", dead: false };
      }
      let res: Response;
      try {
        res = await fetchFn(`${host}/3/device/${token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${auth}`,
            "apns-push-type": "liveactivity",
            "apns-topic": `${cfg.bundleId}.push-type.liveactivity`,
            "apns-priority": "10",
            "content-type": "application/json",
          },
          body: JSON.stringify(payload),
          signal: AbortSignal.timeout(10_000),
        });
      } catch {
        return { ok: false, status: 0, reason: "network", dead: false };
      }
      if (res.ok) {
        await res.body?.cancel();
        return { ok: true, status: res.status, dead: false };
      }
      const raw = ((await res.json().catch(() => null)) as { reason?: unknown } | null)?.reason;
      const reason = typeof raw === "string" ? raw.slice(0, 64) : undefined;
      if (res.status === 403) cached = undefined; // ExpiredProviderToken / InvalidProviderToken → token provider baru
      return {
        ok: false,
        status: res.status,
        reason,
        dead: res.status === 410 || (res.status === 400 && reason === "BadDeviceToken"),
      };
    },
  };
}

let shared: ApnsSender | null | undefined;
/** Sender dari env, satu per isolate (cache JWT provider ikut); null = APNS_* belum lengkap. */
export function apnsFromEnv(): ApnsSender | null {
  if (shared === undefined) {
    const cfg = apnsConfig();
    shared = cfg ? apnsSender(cfg) : null;
  }
  return shared;
}

// ---- payload ------------------------------------------------------------------------------------------------------

export const ACTIVITY_NAME = "Payout";
export const ACTIVITY_URL = "clipper://wallet";
/** Activity tetap tampil sebentar setelah end (iOS maksimal 4 jam). */
export const DISMISS_AFTER_S = 60 * 60;

type Payload = Record<string, unknown>;

/**
 * props ContentState (JSON string). Waktu ISO 8601 UTC; amount rupiah (angka); null = tidak diketahui. payoutId = kunci
 * token update activity ini (app mendaftarkannya lewat api.save_activity_token(token, 'apns_activity', payoutId)).
 */
export interface PayoutProps {
  payoutId: string | null;
  amount: number | null;
  bank: string | null;
  last4: string | null;
  etaAt: string | null;
  startedAt: string | null;
  status: "processing" | "paid" | "failed";
}

function amountOf(p: Payload): number | null {
  const v = typeof p.amount === "number" ? p.amount : typeof p.amount === "string" ? Number(p.amount.trim()) : NaN;
  return Number.isFinite(v) && v >= 0 ? v : null;
}

function isoOf(v: unknown): string | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** bank_code + account_last4 ditambahkan bridge dari rekening milik user itu (svc_payout_methods), bukan dari core. */
export function payoutProps(p: Payload, status: PayoutProps["status"], startedAt: string | null): PayoutProps {
  const bank = typeof p.bank_code === "string" && /^[A-Za-z0-9_]{2,20}$/.test(p.bank_code) ? p.bank_code : null;
  const last4 = typeof p.account_last4 === "string" && /^\d{4}$/.test(p.account_last4) ? p.account_last4 : null;
  const payoutId = typeof p.payout_id === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(p.payout_id) ? p.payout_id : null;
  return { payoutId, amount: amountOf(p), bank, last4, etaAt: isoOf(p.eta_at), startedAt, status };
}

/** stale-date: perkiraan selesai + 15 menit (minimal 15 menit, maksimal 8 jam dari sekarang); tanpa eta = 8 jam. Lewat
 *  itu tanpa event end (token activity belum terdaftar karena app tertutup), layout app menampilkan "cek status". */
function staleDate(etaAt: string | null, nowS: number): number {
  const max = nowS + 8 * 3600;
  if (!etaAt) return max;
  return Math.min(max, Math.max(nowS + 15 * 60, Math.floor(Date.parse(etaAt) / 1000) + 15 * 60));
}

export function startPayload(p: Payload, alert: { title: string; body: string }, nowS: number) {
  const props = payoutProps(p, "processing", new Date(nowS * 1000).toISOString());
  return {
    aps: {
      timestamp: nowS,
      event: "start",
      "attributes-type": "LiveActivityAttributes",
      attributes: { url: ACTIVITY_URL },
      "content-state": { name: ACTIVITY_NAME, props: JSON.stringify(props) },
      "stale-date": staleDate(props.etaAt, nowS),
      alert: { title: alert.title, body: alert.body },
    },
  };
}

export function endPayload(p: Payload, status: "paid" | "failed", nowS: number) {
  return {
    aps: {
      timestamp: nowS,
      event: "end",
      "content-state": { name: ACTIVITY_NAME, props: JSON.stringify(payoutProps(p, status, isoOf(p.started_at))) },
      "dismissal-date": nowS + DISMISS_AFTER_S,
    },
  };
}

// ---- routing (bridge send_push) -------------------------------------------------------------------------------------

export const LIVE_START_EVENT = "payout.processing";
export const LIVE_END_EVENTS: Readonly<Record<string, "paid" | "failed">> = {
  "payout.paid": "paid",
  "payout.failed": "failed",
  "payout.cancelled": "failed",
};

export function isLiveActivityEvent(event: string): boolean {
  return event === LIVE_START_EVENT || Object.hasOwn(LIVE_END_EVENTS, event);
}

/**
 * Live Activity payout untuk satu notifikasi. null = bukan event payout atau fitur mati (APNS_* kosong). Payload sudah
 * diperkaya bridge (bank_code, account_last4). Gagal kirim tidak melempar error: push biasa tetap jalan.
 */
export async function sendPayoutActivity(
  deps: { rpc: Rpc; apns: () => ApnsSender | null; nowS?: () => number },
  userId: string,
  event: string,
  payload: Payload,
  alert: { title: string; body: string },
): Promise<PushResult | null> {
  if (!isLiveActivityEvent(event)) return null;
  const apns = deps.apns();
  if (!apns) return null;
  const nowS = deps.nowS?.() ?? Math.floor(Date.now() / 1000);
  const subs = (await deps.rpc.invoke<PushSubscriptionRow[] | null>("svc_push_subscriptions", { p_user: userId })) ??
    [];
  const result: PushResult = { sent: 0, removed: 0, failed: 0 };
  const reasons: Record<string, number> = {};
  const count = (r: ApnsResult) => {
    if (r.ok) result.sent++;
    else if (r.dead) result.removed++;
    else {
      result.failed++;
      reasons[r.reason ?? String(r.status)] = (reasons[r.reason ?? String(r.status)] ?? 0) + 1;
    }
  };

  if (event === LIVE_START_EVENT) {
    const body = startPayload(payload, alert, nowS);
    await Promise.all(
      subs.filter((s) => s.kind === "apns_start").map(async (s) => {
        const r = await apns.send(s.endpoint, body);
        count(r);
        if (r.ok) await deps.rpc.invoke("svc_touch_push", { p_endpoint: s.endpoint }).catch(() => {});
        else if (r.dead) await deps.rpc.invoke("svc_delete_push", { p_endpoint: s.endpoint });
      }),
    );
  } else {
    const ref = typeof payload.payout_id === "string" ? payload.payout_id : "";
    const body = endPayload(payload, LIVE_END_EVENTS[event], nowS);
    await Promise.all(
      subs.filter((s) => ref && s.kind === "apns_activity" && s.activity_ref === ref).map(async (s) => {
        count(await apns.send(s.endpoint, body));
        await deps.rpc.invoke("svc_delete_push", { p_endpoint: s.endpoint }); // activity berakhir: token update selesai
      }),
    );
  }
  if (result.failed) log("warn", { fn: "bridge", action: "live_activity", event, ...result, reasons });
  return result;
}
