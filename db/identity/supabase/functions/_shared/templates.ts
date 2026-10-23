// Notification templates (F-X01) for email (bridge send_email → Resend) and web push (send_push → VAPID).
// One Indonesian subject/text/html + push title/body/url per event. Every interpolated value is escaped for HTML and
// every link is built from APP_URL / BRAND_URL / ACCOUNTS_URL plus validated path segments — payload values can never
// inject markup or point a link at another host.
// Payload keys read (all optional; core sends ids and may enrich): campaign_id, campaign_title, org_id, org_name,
// platform, handle, amount, reason, expires_at, until, count, invoice_number, due_at, reward_name, title, body.
// DS Android v2: notif clipper selalu membawa angka (views, rupiah, tanggal cair) kalau payload punya: views, rate_per_1k,
// est_amounts[], release_at, hours_left, paused_count, amounts[], fee, paid_at, eta_at, bank_code + account_last4
// (rekening tersamar, diisi bridge identity). Field yang tidak ada (baris antrean lama) → kalimat tanpa angka itu.

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
  "earning.held",
  "payout.processing",
  "payout.paid",
  "payout.failed",
  "fulfillment.delivered",
  "fulfillment.cancelled",
  "payout.cancelled",
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
  "budget.used",
  "budget.projection_low",
  "campaign.settled",
  "org.verified",
  "org.rejected",
  "org.suspended",
  "agency.link_requested",
  "agency.link_approved",
  "refund.requested",
  "refund.paid",
  "managed.draft_ready",
  "admin.alert",
  "account.warned",
  "sanction.appeal_decided",
  "security.notice",
] as const;

export type NotificationEvent = (typeof EVENTS)[number];

/** Promotional events: email only with an unsubscribe link (List-Unsubscribe one-click, RFC 8058). */
export const PROMO_EVENTS: ReadonlySet<string> = new Set(["campaign.new", "broadcast.sent"]);

export interface Links {
  app: string;
  brand: string;
  accounts: string;
  /** Kosong bila ADMIN_URL belum diisi (env baru): email alert admin lalu menautkan ke app, email lain tidak terpengaruh. */
  admin: string;
}

export interface Rendered {
  subject: string;
  text: string;
  html: string;
  push: { title: string; body: string; url: string; actions?: PushAction[] };
}

/** Tombol di notifikasi push (Android; iOS mengabaikan) — sw.js membuka url-nya. */
export interface PushAction {
  action: string;
  title: string;
  url: string;
}

type Payload = Record<string, unknown>;

/** now = waktu render (ms) untuk angka relatif ("±2 menit"); tes mengisinya tetap. */
interface Def {
  title: (p: Payload, now: number) => string;
  lines: (p: Payload, now: number) => (string | null | false | undefined)[];
  cta: string;
  url: (p: Payload, l: Links) => string;
  actions?: (p: Payload, l: Links) => PushAction[];
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
    admin: get("ADMIN_URL") ? safeBaseUrl(get("ADMIN_URL"), "ADMIN_URL") : "",
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

/** platform (satu) atau platforms (array, campaign.new). */
function platform(p: Payload): string {
  const list = Array.isArray(p.platforms) ? p.platforms : [p.platform];
  return list
    .map((v) => txt({ v }, "v", 30))
    .filter(Boolean)
    .map((raw) => PLATFORMS[raw.toLowerCase()] ?? raw)
    .join(", ");
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

/** finance.amount_ref ({amount, reward_type, unit_label}) atau daftarnya di amounts (earning.available, multi-reward). */
function money(p: Payload, key = "amounts"): string {
  const list = Array.isArray(p[key]) ? (p[key] as unknown[]) : key === "amounts" ? [p] : [];
  return list
    .filter((a): a is Payload => typeof a === "object" && a !== null)
    .map((a) => {
      const code = txt(a, "reward_type", 30);
      if (!code || code === "IDR") return rupiah(a);
      const n = typeof a.amount === "number" || typeof a.amount === "string" ? Number(a.amount) : NaN;
      return Number.isFinite(n) ? `${idr.format(n)} ${txt(a, "unit_label", 30) || code}` : "";
    })
    .filter(Boolean)
    .join(" + ");
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
  const d = date(p, key);
  return d ? `${wib.format(d)} WIB` : "";
}

function date(p: Payload, key: string): Date | null {
  const v = p[key];
  if (typeof v !== "string") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

const wibDay = new Intl.DateTimeFormat("id-ID", { timeZone: "Asia/Jakarta", day: "numeric", month: "short" });

/** Tanggal pendek WIB ("27 Okt") — perkiraan cair. */
function day(p: Payload, key: string): string {
  const d = date(p, key);
  return d ? wibDay.format(d) : "";
}

/** Bilangan bulat > 0 (views, jam, jumlah video) format id-ID; 0/kosong/bukan angka → "". */
function qty(p: Payload, key: string): string {
  const v = p[key];
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d{1,15}$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? idr.format(n) : "";
}

/** Rate Rupiah per 1.000 views ("Rp2.000/1K views"). */
function rate(p: Payload): string {
  const r = rupiah(p, "rate_per_1k");
  return r ? `${r}/1K views` : "";
}

/** Rekening tujuan tersamar ("BCA •• 4821"): hanya kalau payload membawa bank_code (+ account_last4) dari bridge identity. */
function bank(p: Payload): string {
  const code = typeof p.bank_code === "string" && /^[A-Za-z0-9_]{2,20}$/.test(p.bank_code)
    ? p.bank_code.replace(/_/g, " ").toUpperCase()
    : "";
  const last4 = typeof p.account_last4 === "string" && /^\d{4}$/.test(p.account_last4) ? p.account_last4 : "";
  return code && last4 ? `${code} •• ${last4}` : code;
}

/** Sisa waktu sampai eta_at saat render: "±2 menit", "±3 jam", lewat → "sebentar lagi". */
function eta(p: Payload, now: number): string {
  const d = date(p, "eta_at");
  if (!d) return "";
  const min = Math.round((d.getTime() - now) / 60_000);
  if (min < 1) return "sebentar lagi";
  return min < 90 ? `±${min} menit` : `±${Math.round(min / 60)} jam`;
}

/** Biaya tarik (instant) > 0; batch tanpa biaya → "". */
function fee(p: Payload): string {
  return Number(p.fee) > 0 ? rupiah(p, "fee") : "";
}

/** Nominal reward non-tunai + namanya ("120 Diamonds", "Voucher (1 voucher)"). */
function reward(p: Payload): string {
  const m = money(p);
  const name = txt(p, "reward_name");
  if (!m) return name;
  return name && !m.toLowerCase().includes(name.toLowerCase()) ? `${name} (${m})` : m;
}

/** Video[ TikTok] kamu di campaign X[ (48.210 views)] — submisi dengan angka yang diketahui. */
function video(p: Payload): string {
  const pf = platform(p);
  const v = qty(p, "views");
  return `Video${pf ? ` ${pf}` : ""} kamu di campaign ${campaign(p)}${v ? ` (${v} views)` : ""}`;
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

const budgetPct = (p: Payload): number => Number(p.pct) >= 100 ? 100 : Number(p.pct) >= 80 ? 80 : 50;

const budgetUsed: Def = {
  title: (p) =>
    budgetPct(p) >= 100
      ? `Budget campaign ${campaign(p)} habis`
      : `Budget campaign ${campaign(p)} terpakai ${budgetPct(p)}%`,
  lines: (p) =>
    budgetPct(p) >= 100
      ? [
        `Seluruh budget campaign ${campaign(p)} sudah terpakai, jadi campaign berhenti menghitung views baru.`,
        "Top-up kalau ingin campaign berjalan lagi.",
      ]
      : [
        `${budgetPct(p)}% budget campaign ${campaign(p)} sudah terpakai.`,
        budgetPct(p) >= 80
          ? "Pertimbangkan top-up supaya campaign tidak berhenti mendadak."
          : "Pantau performanya di dashboard.",
      ],
  cta: "Buka dashboard campaign",
  url: brandCampaign,
};

const ALERT_LABEL: Record<string, string> = {
  "tracking.lag": "job tracking tertinggal",
  "tracking.final_missing": "snapshot final tidak tercatat",
  "fraud.flag_spike": "lonjakan fraud flag",
  "payout.failed": "payout gagal",
  "payout.instant_stuck": "instant withdraw macet",
  "reconcile.ledger": "selisih rekonsiliasi ledger",
  "reconcile.orphans": "selisih rekonsiliasi ID lintas DB",
  "reconcile.bank": "selisih rekonsiliasi mutasi bank",
};

const DEFS: Record<NotificationEvent, Def> = {
  "campaign.new": {
    title: (p) => `Campaign baru: ${txt(p, "campaign_title") || "cek sekarang"}`,
    lines: (p) => [
      `Ada campaign baru${platform(p) ? ` untuk ${platform(p)}` : ""}${
        txt(p, "campaign_title") ? `: ${txt(p, "campaign_title")}` : ""
      }${rate(p) ? ` · rate sampai ${rate(p)}` : ""}.`,
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
      `Brand mengundangmu ke campaign privat ${campaign(p)}${rate(p) ? ` · rate sampai ${rate(p)}` : ""}.`,
      "Buka campaign untuk membaca brief dan mengambil slot.",
    ],
    cta: "Lihat undangan",
    url: appCampaign,
  },
  "claim.expiring": {
    title: (p) =>
      qty(p, "hours_left") ? `Claim kamu habis ±${qty(p, "hours_left")} jam lagi` : "Claim kamu hampir kedaluwarsa",
    lines: (p) => [
      `Claim campaign ${campaign(p)} berakhir ${when(p, "expires_at") || "dalam beberapa jam"}.`,
      "Posting video sesuai brief lalu submit sebelum waktunya habis, atau slot kamu dilepas.",
    ],
    cta: "Submit video",
    url: appCampaign,
  },
  "submission.approved": {
    title: (p) => txt(p, "campaign_title") ? `Submisi kamu di ${campaign(p)} disetujui` : "Submisi kamu disetujui",
    // Baris angka dulu (= body push): "48.210 views dihitung · ±Rp96.400 sejauh ini · cair ±27 Okt".
    lines: (p) => {
      const est = money(p, "est_amounts");
      const nums = [
        qty(p, "views") && `${qty(p, "views")} views dihitung`,
        est ? `±${est} sejauh ini` : rate(p),
        day(p, "release_at") && `cair ±${day(p, "release_at")}`,
      ].filter(Boolean);
      return [
        nums.join(" · "),
        `${video({ ...p, views: null })} disetujui. Views-nya sekarang dihitung untuk earning${
          rate(p) ? ` dengan rate ${rate(p)}` : ""
        }.`,
        (est || day(p, "release_at")) &&
        "Angka ± adalah perkiraan: jumlah akhir mengikuti views final, cap per klip, dan sisa budget campaign.",
      ];
    },
    cta: "Lihat tugas",
    url: (_p, l) => join(l.app, "tasks"),
    // DS Android/iOS 01: notif approve → "Lihat saldo" / "Kirim clip lagi".
    actions: (p, l) => [
      { action: "wallet", title: "Lihat saldo", url: join(l.app, "wallet") },
      { action: "campaign", title: "Kirim clip lagi", url: appCampaign(p, l) },
    ],
  },
  "submission.rejected": {
    title: () => "Submisi kamu ditolak",
    lines: (p) =>
      [
        `${video(p)} ditolak.`,
        reason(p),
        p.final === true ? "" : "Kamu bisa mengajukan banding satu kali dari halaman Tugas.",
      ].filter(Boolean),
    cta: "Lihat tugas",
    url: (_p, l) => join(l.app, "tasks"),
  },
  "submission.forfeited": {
    title: (p) => money(p) ? `Earning ${money(p)} hangus` : "Earning submisi hangus",
    lines: (p) => [
      txt(p, "reason").startsWith("fraud:")
        ? `Earning ${video(p).replace(/^Video/, "video")} dibatalkan setelah pemeriksaan kecurangan.`
        : `${video(p)} tidak bisa diakses lagi (dihapus atau diprivate), jadi earning-nya hangus.`,
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
      } kedaluwarsa atau dicabut, jadi tracking views${
        qty(p, "paused_count") ? ` ${qty(p, "paused_count")} video` : ""
      } berhenti sementara.`,
      "Hubungkan ulang supaya views tetap dihitung.",
    ],
    cta: "Hubungkan ulang",
    url: (_p, l) => join(l.app, "social"),
  },
  "earning.available": {
    title: (p) => money(p) ? `${money(p)} siap ditarik` : "Earning siap ditarik",
    lines: (p) => [
      `${money(p) || "Earning kamu"}${qty(p, "views") ? ` dari ${qty(p, "views")} views` : ""}${
        txt(p, "campaign_title") ? ` di campaign ${campaign(p)}` : ""
      } sudah Tersedia di wallet dan bisa ditarik.`,
    ],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "earning.held": {
    title: (p) => money(p) ? `${money(p)} ditahan sementara` : "Earning kamu ditahan sementara",
    lines: (p) => [
      txt(p, "submission_id")
        ? `Earning ${money(p) ? `${money(p)} dari ` : ""}video kamu di campaign ${
          campaign(p)
        } ditahan selama tim moderasi memeriksanya.`
        : `Penarikan saldo${money(p) ? ` ${money(p)}` : ""} kamu ditahan selama tim moderasi memeriksa akun.`,
      "Earning tetap tercatat. Kalau pemeriksaan selesai tanpa masalah, semuanya berjalan lagi seperti biasa.",
    ],
    cta: "Lihat detail",
    url: (p, l) => join(l.app, txt(p, "submission_id") ? "tasks" : "wallet"),
  },
  // Transfer dimulai (batch diekspor / penyedia instant menerima). eta_at absolut (Live Activity iOS); teks relatif saat render.
  "payout.processing": {
    title: (p) => `Penarikan ${rupiah(p) || "kamu"} sedang diproses`,
    lines: (p, now) => [
      `Lagi ditransfer ${rupiah(p) || "dana kamu"}${bank(p) ? ` ke ${bank(p)}` : ""}${
        eta(p, now) ? ` · ${eta(p, now)}` : ""
      }.`,
      when(p, "eta_at") && `Perkiraan selesai ${when(p, "eta_at")}.`,
      fee(p) && `Biaya tarik instan ${fee(p)} sudah dipotong.`,
      "Kami kabari lagi begitu dana terkirim. Waktu masuk tergantung bank atau e-wallet tujuan.",
    ],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "payout.paid": {
    title: (p) => `Payout ${rupiah(p) || "kamu"} berhasil`,
    lines: (p) => [
      `${rupiah(p) || "Dana"} sudah ditransfer ke ${bank(p) || "rekening kamu"}${
        when(p, "paid_at") ? ` pada ${when(p, "paid_at")}` : ""
      }. Waktu masuk tergantung bank atau e-wallet tujuan.`,
      fee(p) && `Biaya tarik instan ${fee(p)} sudah dipotong.`,
    ],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "payout.failed": {
    title: (p) => `Payout ${rupiah(p) || "kamu"} gagal`,
    lines: (p) => [
      reason(p),
      `Saldo${rupiah(p) ? ` ${rupiah(p)}` : ""} sudah kembali ke wallet. Periksa rekening ${
        bank(p) || "kamu"
      } lalu ajukan penarikan lagi.`,
    ],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "fulfillment.delivered": {
    title: () => "Reward kamu sudah dikirim",
    lines: (p) => [`${reward(p) || "Reward non-tunai kamu"} sudah dikirim. Detailnya ada di tab Reward.`],
    cta: "Lihat reward",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "payout.cancelled": {
    title: (p) => `Penarikan ${rupiah(p) || "kamu"} dibatalkan`,
    lines: (p) => [
      reason(p),
      `${rupiah(p) ? `Saldo ${rupiah(p)}` : "Saldonya"} sudah kembali ke Tersedia dan bisa kamu tarik lagi.`,
    ],
    cta: "Buka wallet",
    url: (_p, l) => join(l.app, "wallet"),
  },
  "fulfillment.cancelled": {
    title: () => "Klaim reward dibatalkan",
    lines: (
      p,
    ) => [reason(p), `Saldo reward${reward(p) ? ` ${reward(p)}` : ""} sudah kembali dan bisa kamu klaim lagi.`],
    cta: "Buka wallet",
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
  // §16 UU PDP: pemberitahuan kebocoran/insiden data ke semua user — transaksional (bukan PROMO_EVENTS), tanpa unsubscribe.
  "security.notice": {
    title: (p) => txt(p, "title") || "Pemberitahuan keamanan data",
    lines: (p) => [para(p, "body")],
    cta: "Pusat akun",
    url: (_p, l) => join(l.accounts, "privacy"),
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
  "budget.used": budgetUsed,
  "budget.projection_low": {
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
  "org.suspended": {
    title: (p) => `Organisasi ${txt(p, "org_name") || "kamu"} ditangguhkan`,
    lines: (p) => [reason(p), "Campaign baru tidak bisa diajukan sampai penangguhan dicabut. Hubungi tim kami."],
    cta: "Buka pengaturan",
    url: (p, l) => brandOrg(p, l, "settings"),
  },
  "agency.link_requested": {
    title: (p) => `${txt(p, "agency_org_name") || "Agency"} minta akses ke ${txt(p, "org_name") || "organisasi kamu"}`,
    lines: () => ["Setujui hanya kalau kamu memang bekerja sama dengan agency ini. Akses bisa dicabut kapan saja."],
    cta: "Tinjau permintaan",
    url: (p, l) => brandOrg(p, l, "settings"),
  },
  "agency.link_approved": {
    title: (p) => `${txt(p, "client_org_name") || "Klien"} menyetujui tautan agency`,
    lines: () => ["Organisasi klien sekarang muncul di pemilih organisasi kamu."],
    cta: "Buka brand",
    url: (_p, l) => l.brand + "/",
  },
  "refund.requested": {
    title: (p) =>
      rupiah(p)
        ? `Refund ${rupiah(p)} untuk campaign ${campaign(p)} sedang diproses`
        : `Refund campaign ${campaign(p)} sedang diproses`,
    lines: () => [
      "Campaign dibatalkan sebelum tayang, jadi seluruh pembayaran dikembalikan.",
      "Tim finance kami akan mentransfer dana dan mengunggah buktinya di halaman tagihan.",
    ],
    cta: "Lihat tagihan",
    url: (p, l) => brandOrg(p, l, "billing"),
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
  }, // F-X01 admin: alert operasional (ops.raise_alert → core bridge → identity notify_admins). Tanpa PII, hanya jenis + id.
  "admin.alert": {
    title: (p) =>
      `Alert ${txt(p, "severity", 20) === "critical" ? "kritis" : "peringatan"}: ${
        ALERT_LABEL[txt(p, "kind", 60)] ?? txt(p, "kind", 60)
      }`,
    lines: (p) => [
      `Jenis: ${txt(p, "kind", 60)} (alert #${txt(p, "alert_id", 20)}).`,
      "Detail dan tombol selesaikan ada di overview admin.",
    ],
    cta: "Buka admin",
    url: (_p, l) => `${l.admin || l.app}/`,
  }, // §12 sanksi bertingkat: peringatan (tingkat pertama) dan hasil banding sanksi (sekali per sanksi)
  "account.warned": {
    title: () => "Peringatan untuk akunmu",
    lines: () => [
      "Tim menemukan aktivitas yang melanggar ketentuan layanan. Ini peringatan pertama.",
      "Pelanggaran berikutnya bisa membuat earning ditahan atau akun ditangguhkan. Kamu bisa membanding di halaman Profil.",
    ],
    cta: "Buka profil",
    url: (_p, l) => join(l.app, "profile"),
  },
  "sanction.appeal_decided": {
    title: (p) => txt(p, "decision", 20) === "overturned" ? "Banding dikabulkan" : "Banding ditolak",
    lines: (p) => [
      txt(p, "decision", 20) === "overturned"
        ? "Sanksi dibatalkan dan efeknya dipulihkan sejauh memungkinkan."
        : "Sanksi tetap berlaku. Keputusan banding bersifat final.",
    ],
    cta: "Buka profil",
    url: (_p, l) => join(l.app, "profile"),
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
  opts: { unsubscribeUrl?: string | null; now?: number } = {},
): Rendered {
  if (!isKnownEvent(event)) throw new Error(`event tidak dikenal: ${event}`);
  const def = DEFS[event];
  const p = payload ?? {};
  const now = opts.now ?? Date.now();
  const title = def.title(p, now);
  const lines = def.lines(p, now).filter((x): x is string => typeof x === "string" && x.length > 0);
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
    ? `<p style="font-size:12px;line-height:1.5;color:#5B6479;margin:16px 0 0">Kamu menerima email ini karena email promosi aktif. <a href="${
      e(unsub)
    }" style="color:#5B6479">Berhenti berlangganan</a>.</p>`
    : "";
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1"><title>${e(title)}</title></head>` +
    `<body style="margin:0;padding:24px;background:#F6F8FC;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#0A1226">` +
    `<div style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:12px;padding:24px">` +
    `<h1 style="font-size:20px;line-height:1.3;margin:0 0 16px">${e(title)}</h1>${htmlLines}` +
    `<p style="margin:24px 0 0"><a href="${
      e(url)
    }" style="display:inline-block;background:#1D5BFF;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:600">${
      e(def.cta)
    }</a></p>` +
    `<p style="font-size:12px;line-height:1.5;color:#5B6479;margin:24px 0 0">Kalau tombol tidak berfungsi, buka ${
      e(url)
    }</p>` +
    `${footer}</div></body></html>`;

  return {
    subject: clip(title, 150),
    text,
    html,
    push: {
      title: clip(title, 80),
      body: clip((lines[0] ?? "").replace(/\s+/g, " "), 180),
      url,
      ...(def.actions ? { actions: def.actions(p, links).slice(0, 2) } : {}),
    },
  };
}
