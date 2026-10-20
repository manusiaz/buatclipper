// identity/bridge — inbound server-to-server entry (§15.5).
//   HMAC (from core, BRIDGE_SECRET_CORE_TO_IDENTITY): send_email, send_push (alur 4), check_ids (alur 10),
//                                                     disburse (alur 11), ban_user (J-A4)
//   apikey (pg_cron → pg_net, member.invoke_function): fraud_device_scan (alur 6, FR-05)
import { isCronRequest } from "../_shared/auth.ts";
import { type CoreBridge, verifyBridge } from "../_shared/bridge.ts";
import { type PiiCrypto, sha256Hex } from "../_shared/crypto.ts";
import type { AuthAdmin, Rpc } from "../_shared/db.ts";
import { type DisbursementProvider, runDisburse } from "../_shared/disburse.ts";
import type { EmailSender } from "../_shared/email.ts";
import {
  HttpError,
  log,
  obj,
  okResponse,
  parseJsonObject,
  readRaw,
  str,
  uuid,
  uuidList,
  wrap,
} from "../_shared/http.ts";
import { banUser, unbanUser } from "../_shared/moderation.ts";
import { type PushSender, sendPushToUser } from "../_shared/push.ts";
import { isKnownEvent, type Links, PROMO_EVENTS, render, safeHttpsUrl } from "../_shared/templates.ts";

export interface BridgeDeps {
  secret: () => string;
  rpc: Rpc;
  core: () => CoreBridge;
  authAdmin: AuthAdmin;
  crypto: () => PiiCrypto;
  email: () => EmailSender;
  push: () => Promise<PushSender>;
  provider: () => DisbursementProvider;
  links: () => Links;
  isCron?: (req: Request) => boolean;
  nowS?: () => number;
}

export const MAX_IDS = 10_000;
export const FR05_SINCE = "1 day";
export const FR05_MIN_ACCOUNTS = 3;

function eventOf(p: Record<string, unknown>): string {
  const event = str(p, "event", { max: 64 });
  if (!isKnownEvent(event)) throw new HttpError(400, "unknown_event", "event notifikasi tidak dikenal");
  return event;
}

/** Optional core notification id (ops.notifications.id, bigint) — positive integer as JSON number or digit string. */
export function notificationId(p: Record<string, unknown>): string | null {
  const v = p.notification_id;
  if (v === undefined || v === null) return null;
  if (typeof v === "number" && Number.isSafeInteger(v) && v > 0) return String(v);
  if (typeof v === "string" && /^[1-9]\d{0,18}$/.test(v)) return v;
  throw new HttpError(400, "invalid_input", "notification_id harus bilangan bulat positif");
}

async function sendEmail(deps: BridgeDeps, p: Record<string, unknown>) {
  const userId = uuid(p, "user_id");
  const event = eventOf(p);
  const nid = notificationId(p);
  const data = obj(p.payload ?? {}, "payload");
  const promo = p.promo === true || PROMO_EVENTS.has(event);
  const unsubscribe = promo ? safeHttpsUrl(p.unsubscribe_url) : null;
  if (promo && !unsubscribe) {
    throw new HttpError(400, "unsubscribe_required", "email promosi wajib unsubscribe_url https");
  }

  const user = await deps.authAdmin.getUser(userId);
  if (!user?.email) return { sent: false, reason: "no_email" };
  const r = render(event, data, deps.links(), { unsubscribeUrl: unsubscribe });
  const res = await deps.email().send({
    to: user.email,
    subject: r.subject,
    text: r.text,
    html: r.html,
    headers: unsubscribe
      ? { "List-Unsubscribe": `<${unsubscribe}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" }
      : undefined,
    // Resend dedupes a key for 24 h: a queue message retried after a successful send does not email twice.
    // Without notification_id the key is derived from the content (same user + event + payload).
    idempotencyKey: nid ? `notif-${nid}` : `notif-${await sha256Hex(`${userId}|${event}|${JSON.stringify(data)}`)}`,
  });
  return { sent: true, id: res.id };
}

/** Alert operasional → role admin terkait + admin_super. Idempoten per (alert, admin): retry tidak mengirim dobel. */
const ALERT_ROLE: Record<string, string> = {
  tracking: "admin_ops",
  fraud: "admin_moderator",
  payout: "admin_finance",
  reconcile: "admin_finance",
};
export async function notifyAdmins(
  deps: Pick<BridgeDeps, "rpc" | "authAdmin" | "email" | "links">,
  p: Record<string, unknown>,
) {
  const kind = str(p, "kind", { max: 60, pattern: /^[a-z_]+\.[a-z_]+$/ });
  const role = ALERT_ROLE[kind.split(".")[0]];
  if (!role) throw new HttpError(400, "invalid_kind", "jenis alert tidak dikirim ke admin");
  const alertId = String(p.alert_id ?? "").replace(/\D/g, "").slice(0, 20);
  const data = { kind, severity: p.severity === "critical" ? "critical" : "warning", alert_id: alertId };
  const ids = (await deps.rpc.invoke<string[] | null>("svc_admin_ids", { p_roles: [role, "admin_super"] })) ?? [];
  const r = render("admin.alert", data, deps.links());
  let sent = 0;
  let failed = 0;
  for (const id of ids) {
    try {
      const user = await deps.authAdmin.getUser(id);
      if (!user?.email) continue;
      await deps.email().send({
        to: user.email,
        subject: r.subject,
        text: r.text,
        html: r.html,
        idempotencyKey: `alert-${alertId || kind}-${id}`,
      });
      sent++;
    } catch (e) {
      failed++; // admin lain tetap dikirimi; core mengulang seluruhnya (idempotency key per alert & admin)
      log("warn", { fn: "bridge", action: "notify_admins", error: e instanceof Error ? e.message : String(e) });
    }
  }
  if (failed) throw new HttpError(503, "email_failed", `${failed} email alert gagal`);
  return { sent };
}

async function sendPush(deps: BridgeDeps, p: Record<string, unknown>) {
  const userId = uuid(p, "user_id");
  const event = eventOf(p);
  const r = render(event, obj(p.payload ?? {}, "payload"), deps.links());
  return await sendPushToUser({ rpc: deps.rpc, sender: await deps.push() }, userId, { ...r.push, event });
}

async function checkIds(deps: BridgeDeps, p: Record<string, unknown>) {
  const missing = await deps.rpc.invoke<Record<string, string[]>>("svc_check_ids", {
    p_user_ids: uuidList(p, "user_ids", MAX_IDS),
    p_method_ids: uuidList(p, "method_ids", MAX_IDS),
    p_recipient_refs: uuidList(p, "recipient_refs", MAX_IDS),
  });
  return { missing };
}

interface DeviceGroup {
  ip: string;
  user_agent: string | null;
  user_ids: string[];
}

/** FR-05: many accounts from one IP + user agent. Core gets only a keyed group id, never the IP or user agent. */
export async function fraudDeviceScan(deps: Pick<BridgeDeps, "rpc" | "core" | "crypto">) {
  const groups = (await deps.rpc.invoke<DeviceGroup[] | null>("shared_device_groups", {
    p_since: FR05_SINCE,
    p_min_accounts: FR05_MIN_ACCOUNTS,
  })) ?? [];
  const crypto = deps.crypto();
  const core = deps.core();
  let flagged = 0;
  let failed = 0;
  for (const g of groups) {
    const users = [...new Set(g.user_ids)].sort();
    const group = await crypto.opaqueId("device", `${g.ip}|${g.user_agent ?? ""}`);
    const score = Math.min(100, 20 * users.length);
    for (const uid of users) {
      try {
        await core.invoke("raise_fraud_flag", {
          target_type: "profile",
          target_id: uid,
          signal: "FR-05",
          score,
          details: {
            device_group: group,
            accounts: users.length,
            related_user_ids: users.filter((u) => u !== uid).slice(0, 20),
            window: FR05_SINCE,
          },
        });
        flagged++;
      } catch {
        failed++; // core keeps one open flag per (target, signal); the next hourly run retries
      }
    }
  }
  log("info", { fn: "bridge", action: "fraud_device_scan", groups: groups.length, flagged, failed });
  return { groups: groups.length, flagged, failed };
}

export function createBridgeHandler(deps: BridgeDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "bridge" }, async (req) => {
    const raw = await readRaw(req, 2 * 1024 * 1024);

    if (req.headers.has("x-bridge-sig")) {
      const { action, payload } = await verifyBridge({
        secret: deps.secret(),
        ts: req.headers.get("x-bridge-ts"),
        sig: req.headers.get("x-bridge-sig"),
        rawBody: raw,
        nowS: deps.nowS?.(),
      });
      switch (action) {
        case "send_email":
          return okResponse(await sendEmail(deps, payload));
        case "send_push":
          return okResponse(await sendPush(deps, payload));
        case "check_ids":
          return okResponse(await checkIds(deps, payload));
        case "notify_admins":
          return okResponse(await notifyAdmins(deps, payload));
        case "disburse":
          return okResponse(await runDisburse(deps, uuid(payload, "payout_id")));
        case "ban_user":
          // core mengirim unban: true untuk membuka login (banding sanksi dikabulkan, R30-2)
          return okResponse(
            payload.unban === true
              ? await unbanUser(deps, { id: null, isSuper: false }, uuid(payload, "user_id"))
              : await banUser(deps, { id: null, isSuper: false }, uuid(payload, "user_id"), payload.duration),
          );
        default:
          throw new HttpError(400, "unknown_action", "action tidak dikenal");
      }
    }

    if ((deps.isCron ?? isCronRequest)(req)) {
      const body = parseJsonObject(raw);
      if (body.action === "fraud_device_scan") return okResponse(await fraudDeviceScan(deps));
      throw new HttpError(400, "unknown_action", "action cron tidak dikenal");
    }
    throw new HttpError(401, "unauthorized", "butuh tanda tangan bridge atau secret key");
  });
}
