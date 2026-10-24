// core/notify (alur 4): kuras queue "email" → bridge identity send_email (+ send_push). Alamat email tidak pernah
// ada di core; identity mencarinya dari user_id. Email promosi membawa unsubscribe_url one-click (RFC 8058).
import { BridgeError } from "../_shared/bridge.ts";
import type { Rpc } from "../_shared/db.ts";
import { hmacHex, HttpError, json, safeEqual } from "../_shared/http.ts";

export interface NotifyDeps {
  rpc: Rpc;
  bridge: (action: string, payload: Record<string, unknown>) => Promise<unknown>;
  unsubscribeSecret: string;
  unsubscribeBase: string; // …/functions/v1/notify/unsubscribe
  now?: () => number;
  budgetMs?: number;
}

export interface NotifySummary {
  dequeued: number;
  sent: number;
  pushed: number;
  dropped: number;
  retried: number;
}

interface Notification {
  user_id: string;
  event: string;
  payload: Record<string, unknown>;
  promo: boolean;
  created?: number;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function unsubscribeUrl(base: string, secret: string, userId: string): Promise<string> {
  const u = new URL(base);
  u.searchParams.set("u", userId);
  u.searchParams.set("s", await hmacHex(secret, userId));
  return u.toString();
}

export async function runNotify(deps: NotifyDeps): Promise<NotifySummary> {
  const now = deps.now ?? Date.now;
  const deadline = now() + (deps.budgetMs ?? 50_000);
  const s: NotifySummary = { dequeued: 0, sent: 0, pushed: 0, dropped: 0, retried: 0 };
  const ack = (id: number) => deps.rpc("worker_ack", { p_queue: "email", p_msg_id: id });

  while (now() < deadline - 5_000) {
    const msgs = (await deps.rpc<
      { msg_id: number; message: { notification_id?: number; email?: boolean; push?: boolean } }[] | null
    >(
      "worker_dequeue",
      { p_queue: "email", p_qty: 20, p_vt_seconds: 120 },
    )) ?? [];
    if (!msgs.length) break;
    s.dequeued += msgs.length;
    let i = 0;
    await Promise.all(Array.from({ length: Math.min(5, msgs.length) }, async () => {
      while (i < msgs.length) {
        const m = msgs[i++];
        try {
          // Pesan lama tanpa flag = email + push.
          await deliver(m.msg_id, m.message?.notification_id, m.message?.email !== false, m.message?.push !== false);
        } catch (e) {
          console.error("notify failed", m.msg_id, e instanceof Error ? e.message : e);
          s.retried++; // tidak di-ack → muncul lagi setelah visibility timeout
        }
      }
    }));
  }
  return s;

  async function deliver(msgId: number, notificationId: number | undefined, wantEmail: boolean, wantPush: boolean) {
    const n = notificationId
      ? await deps.rpc<Notification | null>("worker_notification", { p_id: notificationId })
      : null;
    if (!n) {
      await ack(msgId);
      s.dropped++;
      return;
    }
    // notification_id → Idempotency-Key Resend di identity: retry setelah kirim sukses tidak menghasilkan email dobel.
    const email: Record<string, unknown> = {
      notification_id: notificationId,
      notification_created: n.created, // id + waktu: id bisa terpakai ulang sesudah restore admin (O7-C1)
      user_id: n.user_id,
      event: n.event,
      payload: n.payload ?? {},
      promo: !!n.promo,
    };
    let emailed = false;
    if (wantEmail) {
      if (n.promo) {
        email.unsubscribe_url = await unsubscribeUrl(deps.unsubscribeBase, deps.unsubscribeSecret, n.user_id);
      }
      try {
        await deps.bridge("send_email", email);
        emailed = true;
      } catch (e) {
        if (!(e instanceof BridgeError && e.permanent)) throw e; // 5xx/jaringan → coba lagi nanti
        console.error("send_email rejected", msgId, e.code); // 4xx (user dihapus, tanpa email) → tidak diulang
      }
    }
    if (wantPush) {
      try {
        await deps.bridge("send_push", {
          notification_id: notificationId,
          user_id: n.user_id,
          event: n.event,
          payload: n.payload ?? {},
        });
        s.pushed++;
      } catch (e) {
        console.error("send_push failed", msgId, e instanceof BridgeError ? e.code : e); // push best-effort
      }
    }
    await ack(msgId);
    if (emailed) s.sent++;
    else if (wantEmail) s.dropped++;
  }
}

/** GET/POST /notify/unsubscribe?u=<uuid>&s=<hex HMAC(UNSUBSCRIBE_SECRET, u)> — publik, idempoten. */
export async function handleUnsubscribe(
  req: Request,
  deps: Pick<NotifyDeps, "rpc" | "unsubscribeSecret">,
): Promise<Response> {
  if (req.method !== "GET" && req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  const q = new URL(req.url).searchParams;
  const u = q.get("u") ?? "";
  const sig = (q.get("s") ?? "").toLowerCase();
  if (!UUID.test(u) || !(await safeEqual(sig, await hmacHex(deps.unsubscribeSecret, u)))) {
    throw new HttpError(403, "bad_signature");
  }
  await deps.rpc("worker_unsubscribe", { p_user: u });
  if (req.method === "POST") return json(200, { ok: true }); // List-Unsubscribe-Post: List-Unsubscribe=One-Click
  // Domain *.supabase.co menyajikan HTML sebagai text/plain, jadi konfirmasi dikirim sebagai teks.
  return new Response(
    "Kamu tidak akan menerima email promosi lagi. Atur ulang kapan saja di Pengaturan > Notifikasi.\n",
    {
      status: 200,
      headers: { "content-type": "text/plain; charset=utf-8" },
    },
  );
}
