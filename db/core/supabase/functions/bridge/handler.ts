// core/bridge (PRD §15.5). Dua jenis pemanggil:
//  - identity (HMAC BRIDGE_SECRET_IDENTITY_TO_CORE): get_batch, attach_export, attach_proof, raise_fraud_flag, close_account,
//    get_payout, mark_instant, pph21, fulfillment_export, attach_fulfillment_export → RPC bridge_* 1:1.
//  - pg_cron/pg_net (header apikey): reconcile_ids (alur 10), disburse (alur 11), ban_user → diteruskan ke bridge identity.
import { verifyBridge } from "../_shared/bridge.ts";
import { type Rpc, RpcError } from "../_shared/db.ts";
import { HttpError, json } from "../_shared/http.ts";

type Payload = Record<string, unknown>;

export interface BridgeDeps {
  rpc: Rpc;
  inboundSecret: () => string;
  requireApiKey: (req: Request) => Promise<void>;
  identity: (action: string, payload: Payload) => Promise<unknown>;
  /** Jalankan aksi cron di latar (pg_net menunggu maks 5 detik). */
  background: <T>(task: Promise<T>, sync: boolean) => Promise<{ result?: T; accepted: boolean }>;
}

function pick(p: Payload, ...keys: string[]): unknown {
  for (const k of keys) if (p[k] !== undefined && p[k] !== null && p[k] !== "") return p[k];
  throw new HttpError(400, "bad_payload", `${keys[0]} wajib`);
}
const opt = (p: Payload, k: string, d: unknown = null) => p[k] ?? d;

/** Aksi masuk dari identity → RPC. Kunci payload utama ditulis pertama; alias diterima untuk toleransi. */
export const INBOUND: Record<string, { fn: string; args: (p: Payload) => Payload }> = {
  get_batch: { fn: "bridge_get_batch", args: (p) => ({ p_batch: pick(p, "batch_id", "batch") }) },
  attach_export: {
    fn: "bridge_attach_export",
    args: (p) => ({
      p_batch: pick(p, "batch_id", "batch"),
      p_file_ref: pick(p, "file_ref"),
      p_held: opt(p, "held", []),
      p_exported: pick(p, "exported"),
    }),
  },
  attach_proof: {
    fn: "bridge_attach_proof",
    args: (p) => {
      const target = pick(p, "target");
      if (target !== "batch" && target !== "refund") {
        throw new HttpError(400, "bad_payload", "target harus batch|refund");
      }
      return { p_target: target, p_id: pick(p, "id", "target_id"), p_proof_ref: pick(p, "proof_ref") };
    },
  },
  raise_fraud_flag: {
    fn: "bridge_raise_fraud_flag",
    args: (p) => ({
      p_target_type: pick(p, "target_type"),
      p_target_id: pick(p, "target_id"),
      p_signal: pick(p, "signal"),
      p_score: opt(p, "score"),
      p_details: opt(p, "details", {}),
    }),
  },
  close_account: { fn: "bridge_close_account", args: (p) => ({ p_user: pick(p, "user_id") }) },
  get_payout: { fn: "bridge_get_payout", args: (p) => ({ p_payout: pick(p, "payout_id") }) },
  mark_instant: {
    fn: "bridge_mark_instant",
    args: (p) => ({
      p_payout: pick(p, "payout_id"),
      p_status: pick(p, "status"),
      p_provider_ref: opt(p, "provider_ref"),
      p_error: opt(p, "error"),
    }),
  },
  pph21: { fn: "bridge_pph21", args: (p) => ({ p_from: pick(p, "from"), p_to: pick(p, "to") }) },
  fulfillment_export: {
    fn: "bridge_fulfillment_export",
    args: (p) => ({ p_reward_type: pick(p, "reward_type_id", "reward_type") }),
  },
  attach_fulfillment_export: {
    fn: "bridge_attach_fulfillment_export",
    args: (p) => ({
      p_reward_type: pick(p, "reward_type_id", "reward_type"),
      p_file_ref: pick(p, "file_ref"),
      p_exported: pick(p, "exported"),
    }),
  },
};

const BAN_FOREVER = "876000h"; // ±100 tahun (ban_duration Supabase Auth); "none" = unban

const ids = (v: unknown): string[] => Array.isArray(v) ? v.map(String) : [];

/** Alur 10: ID di core yang sudah tidak ada di identity → antrean review finance (bridge_report_orphans). */
export async function reconcileIds(deps: Pick<BridgeDeps, "rpc" | "identity">, chunkSize = 1000) {
  const all = (await deps.rpc<Record<string, unknown> | null>("bridge_collect_ids")) ?? {};
  const lists = {
    user_ids: ids(all.user_ids),
    method_ids: ids(all.method_ids),
    recipient_refs: ids(all.recipient_refs),
  };
  const missing: Record<keyof typeof lists, string[]> = { user_ids: [], method_ids: [], recipient_refs: [] };
  const rounds = Math.max(1, ...Object.values(lists).map((l) => Math.ceil(l.length / chunkSize)));
  for (let r = 0; r < rounds; r++) {
    const part = Object.fromEntries(
      Object.entries(lists).map(([k, l]) => [k, l.slice(r * chunkSize, (r + 1) * chunkSize)]),
    );
    if (!Object.values(part).some((l) => l.length)) continue;
    const out = (await deps.identity("check_ids", part)) as { missing?: Record<string, unknown> } | null;
    for (const k of Object.keys(missing) as (keyof typeof missing)[]) missing[k].push(...ids(out?.missing?.[k]));
  }
  const total = Object.values(missing).reduce((n, l) => n + l.length, 0);
  if (total) await deps.rpc("bridge_report_orphans", { p_missing: missing });
  return {
    checked: Object.fromEntries(Object.entries(lists).map(([k, l]) => [k, l.length])),
    missing: Object.fromEntries(Object.entries(missing).map(([k, l]) => [k, l.length])),
  };
}

function rpcFailure(e: RpcError): HttpError {
  const m = /^([a-z_]+)(?::\s*(.*))?$/s.exec(e.message.trim());
  if (e.code === "P0002") return new HttpError(404, "not_found", e.message);
  if (e.code === "42501") return new HttpError(403, "forbidden", e.message);
  if (e.code === "P0001" || e.code === "23514" || e.code === "23505") {
    return new HttpError(422, m?.[1] ?? "rejected", e.message);
  }
  if (e.code === "22P02") return new HttpError(400, "bad_payload", e.message);
  console.error("bridge rpc", e.fn, e.code, e.message);
  return new HttpError(500, "internal", "internal error");
}

function fail(e: unknown): Response {
  const err = e instanceof RpcError ? rpcFailure(e) : e instanceof HttpError ? e : null;
  if (!err) {
    console.error("bridge unhandled", e instanceof Error ? e.message : e);
    return json(500, { ok: false, error: { code: "internal", message: "internal error" } });
  }
  return json(err.status, { ok: false, error: { code: err.code, message: err.message } });
}

export function createBridgeHandler(deps: BridgeDeps): (req: Request) => Promise<Response> {
  const cron: Record<string, (p: Payload) => Promise<unknown>> = {
    reconcile_ids: () => reconcileIds(deps),
    disburse: (p) => deps.identity("disburse", { payout_id: pick(p, "payout_id") }),
    ban_user: (p) =>
      deps.identity("ban_user", {
        user_id: pick(p, "user_id"),
        duration: p.unban === true ? "none" : typeof p.duration === "string" && p.duration ? p.duration : BAN_FOREVER,
      }),
  };

  return async (req: Request) => {
    try {
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
      if (req.headers.has("x-bridge-sig")) {
        const msg = await verifyBridge(req, deps.inboundSecret());
        const a = Object.hasOwn(INBOUND, msg.action) ? INBOUND[msg.action] : undefined;
        if (!a) throw new HttpError(400, "unknown_action", msg.action);
        return json(200, { ok: true, data: (await deps.rpc(a.fn, a.args(msg.payload))) ?? null });
      }
      await deps.requireApiKey(req);
      let body: Payload;
      try {
        body = JSON.parse((await req.text()) || "{}");
      } catch {
        throw new HttpError(400, "bad_json");
      }
      const action = String(body?.action ?? "");
      const run = Object.hasOwn(cron, action) ? cron[action] : undefined;
      if (!run) throw new HttpError(400, "unknown_action", action);
      const payload = (body.payload && typeof body.payload === "object" ? body.payload : body) as Payload;
      const out = await deps.background(run(payload), new URL(req.url).searchParams.get("sync") === "1");
      return out.accepted
        ? json(202, { ok: true, data: { accepted: true } })
        : json(200, { ok: true, data: out.result ?? null });
    } catch (e) {
      return fail(e);
    }
  };
}
