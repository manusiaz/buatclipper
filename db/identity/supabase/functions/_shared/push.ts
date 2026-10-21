// Push (F-C14, alur 4) to every E-36 subscription of a user: web push for the PWA (VAPID private key = identity Edge
// Function secret VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT) and Expo push for the native app (Expo relays to
// FCM/APNs; EXPO_ACCESS_TOKEN optional, only when "enhanced push security" is on). Token Live Activity (apns_*) dikirim
// apns.ts, bukan di sini. Endpoints answering 404/410 and Expo tokens reported DeviceNotRegistered in the ticket are gone
// for good and are deleted; accepted Expo tickets go to E-36 push_tickets and their receipts are read later by
// job:push-receipts (resolveExpoReceipts) — DeviceNotRegistered there deletes the token too. Other failures wait.
import type { Rpc } from "./db.ts";
import { env, log } from "./http.ts";

export interface PushSubscriptionRow {
  kind?: "webpush" | "expo" | "apns_start" | "apns_activity";
  endpoint: string;
  p256dh: string | null;
  auth_secret: string | null;
  /** apns_activity: id payout Live Activity-nya. */
  activity_ref?: string | null;
}

/** Expo push ticket (https://docs.expo.dev/push-notifications/sending-notifications/#push-tickets). */
export type ExpoTicket = { status: "ok"; id?: string } | {
  status: "error";
  message?: string;
  details?: { error?: string };
};

/** Expo push receipt: delivery result of a ticket, available for about a day after the send. */
export type ExpoReceipt = { status: "ok" } | { status: "error"; message?: string; details?: { error?: string } };

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

/** Receipts by ticket id (missing = not ready or expired); rejects on HTTP/network failure. */
export type ExpoReceiptFetcher = (ids: string[]) => Promise<Record<string, ExpoReceipt>>;

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

const EXPO_API = "https://exp.host/--/api/v2/push";

async function expoPost<T>(path: string, body: unknown, fetchFn: typeof fetch, accessToken?: string): Promise<T> {
  const res = await fetchFn(`${EXPO_API}/${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw Object.assign(new Error(`expo push ${res.status}`), { statusCode: res.status });
  return (await res.json() as { data?: T }).data as T;
}

export async function expoSend(
  messages: ExpoMessage[],
  fetchFn: typeof fetch = fetch,
  accessToken = Deno.env.get("EXPO_ACCESS_TOKEN"),
): Promise<ExpoTicket[]> {
  const tickets: ExpoTicket[] = [];
  for (let i = 0; i < messages.length; i += 100) { // Expo: max 100 messages per request
    tickets.push(...(await expoPost<ExpoTicket[]>("send", messages.slice(i, i + 100), fetchFn, accessToken) ?? []));
  }
  return tickets;
}

export async function expoReceipts(
  ids: string[],
  fetchFn: typeof fetch = fetch,
  accessToken = Deno.env.get("EXPO_ACCESS_TOKEN"),
): Promise<Record<string, ExpoReceipt>> {
  const out: Record<string, ExpoReceipt> = {};
  for (let i = 0; i < ids.length; i += 1000) { // Expo: max 1000 ids per request
    Object.assign(out, await expoPost("getReceipts", { ids: ids.slice(i, i + 1000) }, fetchFn, accessToken) ?? {});
  }
  return out;
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
    const accepted: { endpoint: string; ticket: string }[] = [];
    await Promise.all(expo.map(async (sub, i) => {
      const t = tickets[i];
      if (t?.status === "ok") {
        result.sent++;
        if (t.id) accepted.push({ endpoint: sub.endpoint, ticket: t.id });
        await deps.rpc.invoke("svc_touch_push", { p_endpoint: sub.endpoint }).catch(() => {});
      } else if (t?.status === "error" && t.details?.error === "DeviceNotRegistered") {
        await deps.rpc.invoke("svc_delete_push", { p_endpoint: sub.endpoint });
        result.removed++;
      } else {
        result.failed++;
      }
    }));
    // Receipt dibaca job:push-receipts ≥ 15 menit lagi; gagal mencatat = token mati baru ketahuan di kiriman berikutnya.
    if (accepted.length) {
      await deps.rpc.invoke("svc_add_push_tickets", {
        p_endpoints: accepted.map((a) => a.endpoint),
        p_tickets: accepted.map((a) => a.ticket),
      }).catch(() => {});
    }
  }
  await Promise.all(
    subs.filter((s) => (s.kind ?? "webpush") === "webpush").map(async (sub) => {
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

export interface ReceiptResult {
  checked: number;
  resolved: number;
  removed: number;
  expired: number;
}

interface DueTicket {
  ticket: string;
  endpoint: string;
}

/**
 * job:push-receipts: receipt ticket Expo ≥ 15 menit → token DeviceNotRegistered dihapus, ticket yang sudah ada receipt-nya
 * dibuang. Receipt belum siap = ticket tetap (svc_resolve_push_tickets membuang yang > 24 jam). Paling banyak `rounds`
 * batch per jalan; sisanya jalan berikutnya.
 */
export async function resolveExpoReceipts(
  deps: { rpc: Rpc; receipts: ExpoReceiptFetcher },
  opts: { batch?: number; rounds?: number } = {},
): Promise<ReceiptResult> {
  const batch = opts.batch ?? 1000;
  const out: ReceiptResult = { checked: 0, resolved: 0, removed: 0, expired: 0 };
  const errors: Record<string, number> = {};
  for (let round = 0; round < (opts.rounds ?? 10); round++) {
    const due = (await deps.rpc.invoke<DueTicket[] | null>("svc_due_push_tickets", { p_limit: batch })) ?? [];
    if (!due.length) break;
    const receipts = await deps.receipts(due.map((t) => t.ticket));
    const done = due.filter((t) => receipts[t.ticket]);
    const dead = new Set<string>();
    for (const t of done) {
      const r = receipts[t.ticket];
      if (r.status !== "error") continue;
      const code = r.details?.error ?? "unknown";
      errors[code] = (errors[code] ?? 0) + 1;
      if (code === "DeviceNotRegistered") dead.add(t.endpoint);
    }
    const res = (await deps.rpc.invoke<Partial<ReceiptResult> | null>("svc_resolve_push_tickets", {
      p_tickets: done.map((t) => t.ticket),
      p_dead_endpoints: [...dead],
    })) ?? {};
    out.checked += due.length;
    out.resolved += res.resolved ?? 0;
    out.removed += res.removed ?? 0;
    out.expired += res.expired ?? 0;
    if (due.length < batch || !done.length) break; // receipt sisanya belum siap
  }
  log("info", { fn: "bridge", action: "push_receipts", ...out, errors }); // hanya jumlah per kode error, tanpa token
  return out;
}
