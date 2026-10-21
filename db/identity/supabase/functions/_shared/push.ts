// Web push (F-C14, alur 4) to every E-36 subscription of a user. The VAPID private key is an identity Edge Function
// secret (VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT). Endpoints answering 404/410 are gone for good
// (RFC 8030 §7.3) and are deleted; other failures are counted and left for the next notification.
import type { Rpc } from "./db.ts";
import { env } from "./http.ts";

export interface PushSubscriptionRow {
  endpoint: string;
  p256dh: string;
  auth_secret: string;
}

export interface PushMessage {
  title: string;
  body: string;
  url: string;
  event: string;
  actions?: { action: string; title: string; url: string }[];
}

export interface PushSender {
  /** Resolves on 2xx; rejects with an object carrying statusCode on HTTP failure. */
  send(sub: PushSubscriptionRow, payload: string): Promise<void>;
}

export interface PushResult {
  sent: number;
  removed: number;
  failed: number;
}

export async function webPushSender(): Promise<PushSender> {
  // Loaded lazily: only bridge send_push needs the Node crypto shim web-push depends on.
  const { default: webpush } = await import("web-push");
  const vapidDetails = {
    subject: env("VAPID_SUBJECT"),
    publicKey: env("VAPID_PUBLIC_KEY"),
    privateKey: env("VAPID_PRIVATE_KEY"),
  };
  return {
    async send(sub, payload) {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_secret } },
        payload,
        { vapidDetails, TTL: 24 * 3600, timeout: 10_000 },
      );
    },
  };
}

function statusOf(err: unknown): number | undefined {
  const s = (err as { statusCode?: unknown })?.statusCode;
  return typeof s === "number" ? s : undefined;
}

export async function sendPushToUser(
  deps: { rpc: Rpc; sender: PushSender },
  userId: string,
  msg: PushMessage,
): Promise<PushResult> {
  const subs = (await deps.rpc.invoke<PushSubscriptionRow[] | null>("svc_push_subscriptions", { p_user: userId })) ??
    [];
  const payload = JSON.stringify(msg);
  const result: PushResult = { sent: 0, removed: 0, failed: 0 };
  await Promise.all(subs.map(async (sub) => {
    let status: number | undefined;
    try {
      await deps.sender.send(sub, payload);
    } catch (err) {
      status = statusOf(err) ?? 0;
    }
    if (status === undefined) {
      result.sent++;
      await deps.rpc.invoke("svc_touch_push", { p_endpoint: sub.endpoint }).catch(() => {});
    } else if (status === 404 || status === 410) {
      await deps.rpc.invoke("svc_delete_push", { p_endpoint: sub.endpoint });
      result.removed++;
    } else {
      result.failed++;
    }
  }));
  return result;
}
