// Push (F-C14, alur 4) to every E-36 subscription of a user: web push for the PWA (VAPID private key = identity Edge
// Function secret VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT) and Expo push for the native app (Expo relays to
// FCM/APNs; EXPO_ACCESS_TOKEN optional, only when "enhanced push security" is on). Endpoints answering 404/410 and
// Expo tokens reported DeviceNotRegistered are gone for good and are deleted; other failures wait for the next one.
import type { Rpc } from "./db.ts";
import { env } from "./http.ts";

export interface PushSubscriptionRow {
  kind?: "webpush" | "expo";
  endpoint: string;
  p256dh: string | null;
  auth_secret: string | null;
}

/** Expo push ticket (https://docs.expo.dev/push-notifications/sending-notifications/#push-tickets). */
export type ExpoTicket = { status: "ok"; id?: string } | {
  status: "error";
  message?: string;
  details?: { error?: string };
};

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
  /** One ticket per message, same order; rejects on HTTP/network failure (whole batch retried next time). */
  sendExpo?(messages: ExpoMessage[]): Promise<ExpoTicket[]>;
}

export interface ExpoMessage {
  to: string;
  title: string;
  body: string;
  sound: "default";
  priority: "high";
  channelId: "default";
  /** Category registered by the app (buttons, e.g. submission_approved → Lihat saldo / Kirim clip lagi). */
  categoryId?: string;
  data: { url: string; event: string; actions: Record<string, string> };
}

/** Same content as the web push payload; button URLs travel in data.actions keyed by action id. */
export function expoMessage(token: string, msg: PushMessage): ExpoMessage {
  const actions = (msg.actions ?? []).slice(0, 2);
  return {
    to: token,
    title: msg.title,
    body: msg.body,
    sound: "default",
    priority: "high",
    channelId: "default",
    ...(actions.length ? { categoryId: msg.event.replace(/\W/g, "_") } : {}),
    data: { url: msg.url, event: msg.event, actions: Object.fromEntries(actions.map((a) => [a.action, a.url])) },
  };
}

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

export async function expoSend(
  messages: ExpoMessage[],
  fetchFn: typeof fetch = fetch,
  accessToken = Deno.env.get("EXPO_ACCESS_TOKEN"),
): Promise<ExpoTicket[]> {
  const tickets: ExpoTicket[] = [];
  for (let i = 0; i < messages.length; i += 100) { // Expo: max 100 messages per request
    const res = await fetchFn(EXPO_PUSH_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify(messages.slice(i, i + 100)),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) throw Object.assign(new Error(`expo push ${res.status}`), { statusCode: res.status });
    const json = await res.json() as { data?: ExpoTicket[] };
    tickets.push(...(json.data ?? []));
  }
  return tickets;
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
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh ?? "", auth: sub.auth_secret ?? "" } },
        payload,
        { vapidDetails, TTL: 24 * 3600, timeout: 10_000 },
      );
    },
    sendExpo: (messages) => expoSend(messages),
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
  const expo = subs.filter((s) => s.kind === "expo");
  if (expo.length) {
    let tickets: ExpoTicket[] = [];
    try {
      tickets = deps.sender.sendExpo ? await deps.sender.sendExpo(expo.map((s) => expoMessage(s.endpoint, msg))) : [];
    } catch {
      tickets = [];
    }
    await Promise.all(expo.map(async (sub, i) => {
      const t = tickets[i];
      if (t?.status === "ok") {
        result.sent++;
        await deps.rpc.invoke("svc_touch_push", { p_endpoint: sub.endpoint }).catch(() => {});
      } else if (t?.status === "error" && t.details?.error === "DeviceNotRegistered") {
        await deps.rpc.invoke("svc_delete_push", { p_endpoint: sub.endpoint });
        result.removed++;
      } else {
        result.failed++;
      }
    }));
  }
  await Promise.all(
    subs.filter((s) => s.kind !== "expo").map(async (sub) => {
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
    }),
  );
  return result;
}
