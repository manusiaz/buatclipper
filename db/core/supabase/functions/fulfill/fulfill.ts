// core/fulfill (F-B03, S-06): pasang kode dari pool (E-41) atau kirim webhook reward ke brand dengan tanda tangan HMAC.
// Hasil dicatat lewat worker_fulfillment_result (SQL mengatur attempts & retry 5 menit). Webhook hanya membawa field
// penerima non-PII (finance.fulfillments.recipient); idempotency_key = id fulfillment supaya brand bisa dedup.
import type { Rpc } from "../_shared/db.ts";
import { hmacHex } from "../_shared/http.ts";

export interface DueFulfillment {
  id: string;
  user_id: string;
  reward_type_id: string;
  amount: number | string;
  recipient: Record<string, unknown> | null;
  fulfillment: string;
  webhook_url: string | null;
  webhook_secret: string | null;
  attempts: number;
}

export interface FulfillDeps {
  rpc: Rpc;
  fetch?: typeof fetch;
  now?: () => number;
  budgetMs?: number;
  timeoutMs?: number;
}

export interface FulfillSummary {
  due: number;
  delivered: number;
  failed: number;
  skipped: number;
}

/** Header x-clipper-signature: t=<ts>,v1=<hex HMAC-SHA256(secret, ts + "." + body)>. */
export async function webhookSignature(secret: string, ts: number, body: string): Promise<string> {
  return `t=${ts},v1=${await hmacHex(secret, `${ts}.${body}`)}`;
}

/** Tolak URL ke jaringan internal (SSRF): wajib https, bukan localhost / IP privat / link-local / metadata. */
export function isPublicHttpsUrl(raw: string): boolean {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.protocol !== "https:" || u.username || u.password) return false;
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (
    h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal") ||
    !h.includes(".") && !h.includes(":")
  ) {
    return false;
  }
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    return !(a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224);
  }
  if (h.includes(":")) {
    return !(h === "::1" || h === "::" || /^(fc|fd|fe8|fe9|fea|feb)/.test(h) || h.startsWith("::ffff:"));
  }
  return true;
}

export async function runFulfill(deps: FulfillDeps): Promise<FulfillSummary> {
  const now = deps.now ?? Date.now;
  const deadline = now() + (deps.budgetMs ?? 50_000);
  const doFetch = deps.fetch ?? fetch;
  const rows = (await deps.rpc<DueFulfillment[] | null>("worker_fulfillments_due", { p_limit: 50 })) ?? [];
  const s: FulfillSummary = { due: rows.length, delivered: 0, failed: 0, skipped: 0 };
  const result = async (id: string, ok: boolean, ref: string | null, error: string | null) => {
    await deps.rpc("worker_fulfillment_result", { p_fulfillment: id, p_ok: ok, p_ref: ref, p_error: error });
    if (ok) s.delivered++;
    else s.failed++;
  };

  let i = 0;
  await Promise.all(Array.from({ length: Math.min(5, rows.length) }, async () => {
    while (i < rows.length && now() < deadline) {
      const f = rows[i++];
      try {
        if (f.fulfillment === "code_pool") {
          const code = await deps.rpc<string | null>("worker_assign_code", { p_fulfillment: f.id });
          // NULL = pool habis (SQL sudah memindah ke on_hold + alert) atau fulfillment bukan requested lagi.
          if (code) await result(f.id, true, code, null);
          else s.failed++;
        } else if (f.fulfillment === "webhook") {
          await webhook(f);
        } else {
          s.skipped++;
        }
      } catch (e) {
        console.error("fulfill failed", f.id, e instanceof Error ? e.message : e); // RPC gagal → jadwal berikutnya
        s.skipped++;
      }
    }
  }));
  return s;

  async function webhook(f: DueFulfillment): Promise<void> {
    if (!f.webhook_url || !f.webhook_secret) return await result(f.id, false, null, "webhook_misconfigured");
    if (!isPublicHttpsUrl(f.webhook_url)) return await result(f.id, false, null, "webhook_url_not_allowed");
    const body = JSON.stringify({
      fulfillment_id: f.id,
      reward_type_id: f.reward_type_id,
      amount: f.amount,
      recipient: f.recipient ?? {},
      idempotency_key: f.id,
    });
    const ts = Math.floor(now() / 1000);
    let res: Response;
    try {
      res = await doFetch(f.webhook_url, {
        method: "POST",
        redirect: "manual",
        headers: {
          "content-type": "application/json",
          "x-clipper-signature": await webhookSignature(f.webhook_secret, ts, body),
          "idempotency-key": f.id,
        },
        body,
        signal: AbortSignal.timeout(deps.timeoutMs ?? 10_000),
      });
    } catch (e) {
      return await result(
        f.id,
        false,
        null,
        e instanceof DOMException && e.name === "TimeoutError" ? "timeout" : "network_error",
      );
    }
    if (res.status < 200 || res.status >= 300) {
      await res.body?.cancel();
      return await result(f.id, false, null, `http_${res.status}`);
    }
    let ref: string | null = null;
    try {
      const out = await res.json();
      const r = out?.reference ?? out?.ref ?? out?.id;
      ref = r == null ? null : String(r).slice(0, 200);
    } catch {
      // body kosong / bukan JSON: tetap sukses
    }
    await result(f.id, true, ref, null);
  }
}
