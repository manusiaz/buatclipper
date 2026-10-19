// Notification templates (F-X01) for email (bridge send_email → Resend) and web push (send_push → VAPID).
// One Indonesian subject/text/html + push title/body/url per event. Every interpolated value is escaped for HTML and
// every link is built from APP_URL / BRAND_URL / ACCOUNTS_URL plus validated path segments — payload values can never
// inject markup or point a link at another host.
// Payload keys read (all optional; core sends ids and may enrich): campaign_id, campaign_title, org_id, org_name,
// platform, handle, amount, reason, expires_at, until, count, invoice_number, due_at, reward_name, title, body.

export const EVENTS = [
  "campaign.new",
  "campaign.invited",
  "claim.expiring",
  "submission.approved",
  "submission.rejected",
  "submission.forfeited",
  "submission.pending_review",
  "social.token_expired",
  "earning.available",
  "payout.paid",
  "payout.failed",
  "fulfillment.delivered",
  "kyc.approved",
  "kyc.rejected",
  "broadcast.sent",
  "account.suspended",
  "account.banned",
  "invoice.issued",
  "invoice.paid",
  "campaign.approved",
  "campaign.rejected",
  "campaign.live",
  "campaign.budget_50",
  "campaign.budget_80",
  "campaign.budget_100",
  "campaign.projection_low",
  "campaign.settled",
  "org.verified",
  "org.rejected",
  "refund.paid",
  "managed.draft_ready",
] as const;

export type NotificationEvent = (typeof EVENTS)[number];

/** Promotional events: email only with an unsubscribe link (List-Unsubscribe one-click, RFC 8058). */
export const PROMO_EVENTS: ReadonlySet<string> = new Set(["campaign.new", "broadcast.sent"]);

export interface Links {
  app: string;
  brand: string;
  accounts: string;
}

export interface Rendered {
  subject: string;
  text: string;
  html: string;
  push: { title: string; body: string; url: string };
}

type Payload = Record<string, unknown>;

interface Def {
  title: (p: Payload) => string;
  lines: (p: Payload) => (string | null | false | undefined)[];
  cta: string;
  url: (p: Payload, l: Links) => string;
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** Absolute http(s) base URL without trailing slash; http only for local hosts. */
export function safeBaseUrl(raw: string | undefined, name: string): string {
  let u: URL;
  try {
    u = new URL(raw ?? "");
  } catch {
    throw new Error(`${name} harus URL absolut`);
  }
  const local = ["localhost", "127.0.0.1"].includes(u.hostname) || u.hostname.endsWith(".localhost");
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) throw new Error(`${name} harus https`);
  return u.origin + u.pathname.replace(/\/+$/, "");
}

/** https URL supplied by core (unsubscribe); null when unusable. */
export function safeHttpsUrl(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length > 2000) return null;
  try {
    const u = new URL(raw);
    const local = ["localhost", "127.0.0.1"].includes(u.hostname);
    return u.protocol === "https:" || (u.protocol === "http:" && local) ? u.toString() : null;
  } catch {
    return null;
  }
}

export function linksFromEnv(get: (n: string) => string | undefined = (n) => Deno.env.get(n)): Links {
  return {
    app: safeBaseUrl(get("APP_URL"), "APP_URL"),
    brand: safeBaseUrl(get("BRAND_URL"), "BRAND_URL"),
    accounts: safeBaseUrl(get("ACCOUNTS_URL"), "ACCOUNTS_URL"),
  };
}

// ---- payload helpers ---------------------------------------------------------------------------------------------

function txt(p: Payload, key: string, max = 120): string {
  const v = p[key];
  if (typeof v !== "string" && typeof v !== "number") return "";
  const s = String(v).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

/** Multi-line free text (broadcast body): keeps line breaks, trims, caps length. */
function para(p: Payload, key: string, max = 2000): string {
  const v = p[key];
  if (typeof v !== "string") return "";
  const s = v.replace(/\r\n?/g, "\n").replace(/[^\S\n]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

function seg(v: unknown): string | null {
  return typeof v === "string" && /^[A-Za-z0-9_-]{1,80}$/.test(v) ? v : null;
}

const PLATFORMS: Record<string, string> = {
  tiktok: "TikTok",
  instagram: "Instagram",
  youtube: "YouTube",
  threads: "Threads",
  facebook: "Facebook",
  x: "X",
};

function platform(p: Payload): string {
  const raw = txt(p, "platform", 30);
  return PLATFORMS[raw.toLowerCase()] ?? raw;
}

function campaign(p: Payload): string {
  return txt(p, "campaign_title") || "ini";
}

const idr = new Intl.NumberFormat("id-ID", { maximumFractionDigits: 2 });

function rupiah(p: Payload, key = "amount"): string {
  const v = p[key];
  const s = typeof v === "number" ? v.toFixed(2) : typeof v === "string" ? v.trim() : "";
  const m = /^(\d{1,16})(?:\.(\d{1,2}))?$/.exec(s);
  if (!m) return "";
  return "Rp" + idr.format(Number(`${m[1]}.${m[2] ?? "0"}`));
}

const wib = new Intl.DateTimeFormat("id-ID", {
  timeZone: "Asia/Jakarta",
  day: "numeric",
  month: "long",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

function when(p: Payload, key: string): string {
  const v = p[key];
  if (typeof v !== "string") return "";
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? "" : `${wib.format(d)} WIB`;
}

function reason(p: Payload): string | null {
  const r = txt(p, "reason", 300);
  return r ? `Alasan: ${r}` : null;
}

function join(base: string, ...parts: (string | null)[]): string {
  return [base, ...parts.filter((x): x is string => !!x).map(encodeURIComponent)].join("/");
}

function appCampaign(p: Payload, l: Links): string {
  const id = seg(p.campaign_id);
  return id ? join(l.app, "campaigns", id) : join(l.app, "campaigns");
}

function brandOrg(p: Payload, l: Links, ...rest: string[]): string {
  const org = seg(p.org_id);
  return org ? join(l.brand, org, ...rest) : l.brand + "/";
}

function brandCampaign(p: Payload, l: Links): string {
  const org = seg(p.org_id);
  const id = seg(p.campaign_id);
  if (!org) return l.brand + "/";
  return id ? join(l.brand, org, "campaigns", id) : join(l.brand, org, "campaigns");
}

function budget(pct: number): Def {
  return {
    title: (p) =>
      pct >= 100 ? `Budget campaign ${campaign(p)} habis` : `Budget campaign ${campaign(p)} terpakai ${pct}%`,
    lines: (p) =>
      pct >= 100
        ? [
          `Seluruh budget campaign ${campaign(p)} sudah terpakai, jadi campaign berhenti menghitung views baru.`,
          "Top-up kalau ingin campaign berjalan lagi.",
        ]
        : [
          `${pct}% budget campaign ${campaign(p)} sudah terpakai.`,
          pct >= 80
            ? "Pertimbangkan top-up supaya campaign tidak berhenti mendadak."
            : "Pantau performanya di dashboard.",
        ],
    cta: "Buka dashboard campaign",
    url: brandCampaign,
  };
}

const DEFS: Record<NotificationEvent, Def> = {
  "campaign.new": {
    title: (p) => `Campaign baru: ${txt(p, "campaign_title") || "cek sekarang"}`,
    lines: (p) => [
      `Ada campaign baru${platform(p) ? ` untuk ${platform(p)}` : ""}${
        txt(p, "campaign_title") ? `: ${txt(p, "campaign_title")}` : ""
      }.`,
      "Ambil sebelum slot atau budget-nya habis.",
    ],
    cta: "Lihat campaign",
    url: appCampaign,
  },
  "campaign.invited": {
    title: (p) => `Kamu diundang ke campaign ${campaign(p)}`,
    lines: (
      p,
    ) => [
      `Brand mengundangmu ke campaign privat ${campaign(p)}.`,
      "Buka campaign untuk membaca brief dan mengambil slot.",
    ],
    cta: "Lihat undangan",
    url: appCampaign,
  },
  "claim.expiring": {
    title: () => "Claim kamu hampir kedaluwarsa",
    lines: (p) => [
      `Claim campaign ${campaign(p)} berakhir ${when(p, "expires_at") || "dalam beberapa jam"}.`,
      "Posting video sesuai brief lalu submit sebelum waktunya habis, atau slot kamu dilepas.",
    ],
    cta: "Submit video",
    url: appCampaign,
  },
  "submission.approved": {
    title: () => "Submisi kamu disetujui",
    lines: (p) => [`Video kamu di campaign ${campaign(p)} disetujui. Views-nya sekarang dihitung untuk earning.`],
    cta: "Lihat tugas",
    url: (_p, l) => join(l.app, "tasks"),
  },
  "submission.rejected": {
    title: () => "Submisi kamu ditolak",
    lines: (p) => [
      `Video kamu di campaign ${campaign(p)} ditolak.`,
      reason(p),
      "Kamu bisa mengajukan banding satu kali dari halaman Tugas.",
    ],
    cta: "Lihat tugas",
    url: (_p, l) => join(l.app, "tasks"),
  },
  "submission.forfeited": {
    title: () => "Earning submisi hangus",
    lines: (p) => [
      `Video kamu di campaign ${
        campaign(p)
      } tidak bisa diakses lagi (dihapus atau diprivate), jadi earning-nya hangus.`,
      reason(p),
    ],
    cta: "Lihat tugas",
    url: (_p, l) => join(l.app, "tasks"),
  },
  "submission.pending_review": {
    title: (p) => `Submisi menunggu review: ${campaign(p)}`,
    lines: (p) => [
      `${txt(p, "count", 6) ? `${txt(p, "count", 6)} submisi` : "Submisi baru"} di campaign ${
        campaign(p)
      } menunggu review.`,
      "Tanpa keputusan dalam 72 jam, submisi disetujui otomatis.",
    ],
    cta: "Review sekarang",
    url: (p, l) => brandOrg(p, l, "review"),
  },
  "social.token_expired": {
    title: (p) => `Hubungkan ulang akun ${platform(p) || "sosmed"} kamu`,
    lines: (p) => [
      `Izin akun ${platform(p) || "sosmed"}${
        txt(p, "handle", 60) ? ` @${txt(p, "handle", 60)}` : ""
      } kedaluwarsa atau dicabut, jadi tracking views berhenti sementara.`,
      "Hubungkan ulang supaya views tetap dihitung.",
    ],
    cta: "Hubungkan ulang",
    url: (_p, l) => join(l.app, "social"),
  },
  "earning.available": {
    title: () => "Earning siap ditarik",
    lines: (p) => [`${rupiah(p) || "Earning kamu"} sudah Tersedia di wallet dan bisa ditarik.`],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "payout.paid": {
    title: (p) => `Payout ${rupiah(p) || "kamu"} berhasil`,
    lines: () => ["Dana sudah ditransfer ke rekening kamu. Waktu masuk tergantung bank atau e-wallet tujuan."],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "payout.failed": {
    title: (p) => `Payout ${rupiah(p) || "kamu"} gagal`,
    lines: (p) => [reason(p), "Saldo sudah kembali ke wallet. Periksa rekening kamu lalu ajukan penarikan lagi."],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "fulfillment.delivered": {
    title: () => "Reward kamu sudah dikirim",
    lines: (p) => [`${txt(p, "reward_name") || "Reward non-tunai kamu"} sudah dikirim. Detailnya ada di tab Reward.`],
    cta: "Lihat reward",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "kyc.approved": {
    title: () => "KYC kamu disetujui",
    lines: () => ["Data identitas kamu sudah diverifikasi. Sekarang kamu bisa menarik saldo."],
    cta: "Lihat status KYC",
    url: (_p, l) => join(l.accounts, "kyc"),
  },
  "kyc.rejected": {
    title: () => "KYC kamu ditolak",
    lines: (p) => [reason(p), "Perbaiki data atau foto KTP lalu kirim ulang dari halaman KYC."],
    cta: "Perbaiki KYC",
    url: (_p, l) => join(l.accounts, "kyc"),
  },
  "broadcast.sent": {
    title: (p) => txt(p, "title") || "Pengumuman",
    lines: (p) => [para(p, "body")],
    cta: "Buka aplikasi",
    url: (_p, l) => join(l.app, "campaigns"),
  },
  "account.suspended": {
    title: () => "Akun kamu ditangguhkan",
    lines: (p) => [
      `Akun kamu ditangguhkan${when(p, "until") ? ` sampai ${when(p, "until")}` : ""}.`,
      reason(p),
      "Selama ditangguhkan kamu tidak bisa claim, submit, atau menarik saldo. Hubungi bantuan kalau menurutmu ini keliru.",
    ],
    cta: "Buka aplikasi",
    url: (_p, l) => l.app + "/",
  },
  "account.banned": {
    title: () => "Akun kamu diblokir",
    lines: (p) => [
      "Akun kamu diblokir karena pelanggaran ketentuan layanan.",
      reason(p),
      "Hubungi bantuan kalau menurutmu ini keliru.",
    ],
    cta: "Pusat akun",
    url: (_p, l) => l.accounts + "/",
  },
  "invoice.issued": {
    title: (p) => `Invoice ${txt(p, "invoice_number", 40) || "baru"} terbit`,
    lines: (p) => [
      `Invoice${txt(p, "invoice_number", 40) ? ` ${txt(p, "invoice_number", 40)}` : ""}${
        rupiah(p) ? ` sebesar ${rupiah(p)}` : ""
      } sudah terbit${when(p, "due_at") ? `, jatuh tempo ${when(p, "due_at")}` : ""}.`,
      "Bayar lewat QRIS atau transfer bank sesuai instruksi di halaman tagihan.",
    ],
    cta: "Lihat tagihan",
    url: (p, l) => brandOrg(p, l, "billing"),
  },
  "invoice.paid": {
    title: () => "Pembayaran diterima",
    lines: (p) => [
      `Pembayaran${txt(p, "invoice_number", 40) ? ` invoice ${txt(p, "invoice_number", 40)}` : ""}${
        rupiah(p) ? ` sebesar ${rupiah(p)}` : ""
      } sudah kami terima.`,
    ],
    cta: "Lihat tagihan",
    url: (p, l) => brandOrg(p, l, "billing"),
  },
  "campaign.approved": {
    title: (p) => `Campaign ${campaign(p)} disetujui`,
    lines: () => ["Campaign kamu lolos review dan akan tayang sesuai jadwal."],
    cta: "Buka campaign",
    url: brandCampaign,
  },
  "campaign.rejected": {
    title: (p) => `Campaign ${campaign(p)} ditolak`,
    lines: (p) => [reason(p), "Perbaiki campaign lalu ajukan lagi."],
    cta: "Buka campaign",
    url: brandCampaign,
  },
  "campaign.live": {
    title: (p) => `Campaign ${campaign(p)} sudah tayang`,
    lines: () => ["Clipper sekarang bisa mengambil campaign kamu. Pantau views dan budget dari dashboard."],
    cta: "Buka dashboard campaign",
    url: brandCampaign,
  },
  "campaign.budget_50": budget(50),
  "campaign.budget_80": budget(80),
  "campaign.budget_100": budget(100),
  "campaign.projection_low": {
    title: (p) => `Proyeksi campaign ${campaign(p)} di bawah target`,
    lines: () => [
      "Dengan laju sekarang, kurang dari separuh budget diperkirakan terpakai sampai campaign berakhir.",
      "Naikkan rate, perpanjang jadwal, atau undang clipper supaya budget terserap.",
    ],
    cta: "Buka dashboard campaign",
    url: brandCampaign,
  },
  "campaign.settled": {
    title: (p) => `Campaign ${campaign(p)} selesai`,
    lines: () => [
      "Campaign sudah selesai dan laporan akhirnya siap.",
      "Sisa budget mengikuti pilihan refund atau rollover di halaman tagihan.",
    ],
    cta: "Lihat laporan",
    url: brandCampaign,
  },
  "org.verified": {
    title: (p) => `Organisasi ${txt(p, "org_name") || "kamu"} terverifikasi`,
    lines: () => ["Sekarang kamu bisa mengajukan campaign."],
    cta: "Buat campaign",
    url: (p, l) => brandOrg(p, l, "campaigns", "new"),
  },
  "org.rejected": {
    title: () => "Verifikasi organisasi ditolak",
    lines: (p) => [reason(p), "Perbaiki data organisasi lalu ajukan ulang dari pengaturan."],
    cta: "Buka pengaturan",
    url: (p, l) => brandOrg(p, l, "settings"),
  },
  "refund.paid": {
    title: (p) => `Refund ${rupiah(p) || "kamu"} sudah ditransfer`,
    lines:
      () => ["Dana refund sudah kami transfer ke rekening organisasi kamu. Bukti transfer ada di halaman tagihan."],
    cta: "Lihat tagihan",
    url: (p, l) => brandOrg(p, l, "billing"),
  },
  "managed.draft_ready": {
    title: (p) => `Draft campaign ${campaign(p)} siap disetujui`,
    lines: () => [
      "Tim kami sudah menyusun campaign dari brief kamu.",
      "Periksa ringkasannya, lalu setujui dan bayar supaya campaign bisa direview.",
    ],
    cta: "Periksa draft",
    url: (p, l) => {
      const base = brandOrg(p, l, "campaigns", "new");
      const id = seg(p.campaign_id);
      return id && seg(p.org_id) ? `${base}?campaign=${encodeURIComponent(id)}` : base;
    },
  },
};

export function isKnownEvent(e: string): e is NotificationEvent {
  return Object.prototype.hasOwnProperty.call(DEFS, e);
}

function clip(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

export function render(
  event: string,
  payload: Payload,
  links: Links,
  opts: { unsubscribeUrl?: string | null } = {},
): Rendered {
  if (!isKnownEvent(event)) throw new Error(`event tidak dikenal: ${event}`);
  const def = DEFS[event];
  const p = payload ?? {};
  const title = def.title(p);
  const lines = def.lines(p).filter((x): x is string => typeof x === "string" && x.length > 0);
  const url = def.url(p, links);
  const unsub = opts.unsubscribeUrl ? safeHttpsUrl(opts.unsubscribeUrl) : null;

  const textParts = [title, "", ...lines.flatMap((l) => [l, ""]), `${def.cta}: ${url}`];
  if (unsub) textParts.push("", `Berhenti menerima email promosi: ${unsub}`);
  const text = textParts.join("\n") + "\n";

  const e = escapeHtml;
  const htmlLines = lines
    .map((l) => `<p style="font-size:15px;line-height:1.6;margin:0 0 12px">${e(l).replace(/\n/g, "<br>")}</p>`)
    .join("");
  const footer = unsub
    ? `<p style="font-size:12px;line-height:1.5;color:#78716c;margin:16px 0 0">Kamu menerima email ini karena email promosi aktif. <a href="${
      e(unsub)
    }" style="color:#78716c">Berhenti berlangganan</a>.</p>`
    : "";
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1"><title>${e(title)}</title></head>` +
    `<body style="margin:0;padding:24px;background:#f5f5f4;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1c1917">` +
    `<div style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;padding:24px">` +
    `<h1 style="font-size:20px;line-height:1.3;margin:0 0 16px">${e(title)}</h1>${htmlLines}` +
    `<p style="margin:24px 0 0"><a href="${
      e(url)
    }" style="display:inline-block;background:#1c1917;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:600">${
      e(def.cta)
    }</a></p>` +
    `<p style="font-size:12px;line-height:1.5;color:#78716c;margin:24px 0 0">Kalau tombol tidak berfungsi, buka ${
      e(url)
    }</p>` +
    `${footer}</div></body></html>`;

  return {
    subject: clip(title, 150),
    text,
    html,
    push: { title: clip(title, 80), body: clip((lines[0] ?? "").replace(/\s+/g, " "), 180), url },
  };
}
