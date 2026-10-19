// Email notifications via Resend REST API (alur 4). The recipient address is looked up in identity (auth.users) and
// never leaves this project except to Resend. Env: RESEND_API_KEY, EMAIL_FROM ("Clipper <no-reply@notif.example.com>").
import { HttpError } from "./http.ts";

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
  headers?: Record<string, string>;
  idempotencyKey?: string;
}

export interface EmailSender {
  send(msg: EmailMessage): Promise<{ id: string }>;
}

export function resendSender(opts: { apiKey: string; from: string; fetchFn?: typeof fetch }): EmailSender {
  const fetchFn = opts.fetchFn ?? fetch;
  return {
    async send(msg) {
      const headers: Record<string, string> = {
        authorization: `Bearer ${opts.apiKey}`,
        "content-type": "application/json",
      };
      // Resend dedupes a repeated key for 24 h, so a bridge retry after a timeout does not send twice.
      if (msg.idempotencyKey) headers["Idempotency-Key"] = msg.idempotencyKey;
      let res: Response;
      try {
        res = await fetchFn("https://api.resend.com/emails", {
          method: "POST",
          headers,
          body: JSON.stringify({
            from: opts.from,
            to: [msg.to],
            subject: msg.subject,
            text: msg.text,
            html: msg.html,
            ...(msg.headers ? { headers: msg.headers } : {}),
          }),
          signal: AbortSignal.timeout(15_000),
        });
      } catch {
        throw new HttpError(503, "email_unavailable", "layanan email tidak bisa dihubungi");
      }
      const body = await res.json().catch(() => ({})) as { id?: string; name?: string };
      if (res.ok && typeof body.id === "string") return { id: body.id };
      if (res.status === 429 || res.status >= 500) {
        throw new HttpError(503, "email_unavailable", "layanan email sedang sibuk");
      }
      // 4xx: request refused (bad address, unverified domain, idempotency conflict) — retrying will not help.
      throw new HttpError(422, "email_rejected", `email ditolak penyedia (${body.name ?? res.status})`);
    },
  };
}

/** Stack lokal saja: kirim ke Mailpit (HTTP API /api/v1/send) supaya email notifikasi bisa dilihat & dites E2E. */
export function mailpitSender(opts: { baseUrl: string; from: string; fetchFn?: typeof fetch }): EmailSender {
  const fetchFn = opts.fetchFn ?? fetch;
  const m = /^(.*?)\s*<(.+)>$/.exec(opts.from);
  const from = m ? { Name: m[1], Email: m[2] } : { Email: opts.from };
  return {
    async send(msg) {
      const res = await fetchFn(`${opts.baseUrl.replace(/\/$/, "")}/api/v1/send`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          From: from,
          To: [{ Email: msg.to }],
          Subject: msg.subject,
          Text: msg.text,
          HTML: msg.html,
        }),
      }).catch(() => null);
      const body = await res?.json().catch(() => ({})) as { ID?: string } | undefined;
      if (!res?.ok || !body?.ID) throw new HttpError(503, "email_unavailable", "mailpit tidak bisa dihubungi");
      return { id: body.ID };
    },
  };
}
