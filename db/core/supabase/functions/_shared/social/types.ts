// PlatformAdapter (PRD §11): semua logika platform hidup di adapter, engine earning tidak tahu platform.

export type Platform = "tiktok" | "instagram" | "youtube" | "threads" | "facebook" | "x";
export const PLATFORMS: readonly Platform[] = ["tiktok", "instagram", "youtube", "threads", "facebook", "x"];
export const isPlatform = (p: unknown): p is Platform =>
  typeof p === "string" && (PLATFORMS as readonly string[]).includes(p);

/** Isi secret Vault (string JSON). meta = id platform yang dibutuhkan adapter (open_id, channel, page, …). */
export interface StoredToken {
  v: 1;
  access_token: string;
  refresh_token?: string | null;
  expires_at?: string | null; // ISO; null = tidak kedaluwarsa (token Page Facebook)
  refresh_expires_at?: string | null;
  scope?: string | null;
  meta?: Record<string, string>;
}

export interface Profile {
  externalId: string;
  handle: string;
  followers: number | null;
  createdAt?: string | null;
  accountType?: string | null;
  /** Disimpan ke token.meta saat connect (mis. channel & playlist uploads YouTube). */
  tokenMeta?: Record<string, string>;
}

export interface Video {
  postId: string;
  url: string;
  caption: string;
  postedAt: string; // ISO
  durationSec: number | null; // null = API tidak memberi durasi → review manual kalau campaign berbatas durasi
  thumbnail: string | null;
}

export interface Metrics {
  postId: string;
  views: number;
  likes: number | null;
  comments: number | null;
  shares: number | null;
  caption: string | null;
  extra: Record<string, unknown>; // reach, avg_watch_time, skip_rate, traffic_sources, countries, …
  raw: unknown;
}

export type MetricResult =
  | Metrics
  | { postId: string; gone: true; reason: string } // dihapus / private → worker_post_gone
  | { postId: string; retry: true; reason: string } // rate limit / angka belum ada → jangan ack, coba lagi
  | { postId: string; failed: true; reason: string }; // error lain per post → ack tanpa snapshot (log)

export const isMetrics = (r: MetricResult): r is Metrics => !("gone" in r) && !("retry" in r) && !("failed" in r);

export interface FetchOptions {
  /** Snapshot final (lock): adapter boleh mengambil data tambahan yang mahal (YouTube Analytics negara & sumber traffic). */
  final?: boolean;
  /** posted_at per postId (startDate laporan YouTube Analytics). */
  postedAt?: Record<string, string>;
}

export interface PlatformAdapter {
  readonly platform: Platform;
  /** PKCE: required (X), optional (Google), none (Meta, TikTok web). */
  readonly pkce: "required" | "optional" | "none";
  /** Jumlah post per panggilan metrik (YouTube 50, TikTok 20, X 100, Meta 1). */
  readonly maxBatch: number;
  authorizeUrl(redirectUri: string, state: string, codeChallenge?: string): string;
  exchangeCode(
    code: string,
    redirectUri: string,
    codeVerifier?: string,
    opts?: { pageId?: string },
  ): Promise<StoredToken>;
  profile(token: StoredToken): Promise<Profile>;
  listVideos(token: StoredToken, sinceIso: string): Promise<Video[]>;
  /** Ambil satu post milik akun token; post akun lain → AdapterError('not_owner'). */
  getPost(token: StoredToken, postIdOrUrl: string): Promise<Video>;
  fetchMetrics(token: StoredToken, postIds: string[], opts?: FetchOptions): Promise<MetricResult[]>;
  refreshToken(token: StoredToken): Promise<StoredToken>;
}

export class TokenExpired extends Error {
  constructor(message = "token expired", public revoked = false) {
    super(message);
  }
}
export class PostGone extends Error {}
export class Retryable extends Error {
  /** Retry-After dari penyedia (detik), kalau ada. */
  constructor(message?: string, public retryAfterSec?: number) {
    super(message);
  }
}
/** Error bisnis dengan kode stabil (ig_personal, oauth_failed, not_owner, bad_url, scope_missing, page_ambiguous, …). */
export class AdapterError extends Error {
  constructor(public code: string, message = code, public detail?: unknown) {
    super(message);
  }
}

export function parseToken(raw: string | null | undefined): StoredToken | null {
  if (!raw) return null;
  try {
    const t = JSON.parse(raw);
    return t && typeof t.access_token === "string" ? { v: 1, ...t } : null;
  } catch {
    return null;
  }
}

export function expiresAt(expiresInS: unknown, now = Date.now()): string | null {
  const n = Number(expiresInS);
  return Number.isFinite(n) && n > 0 ? new Date(now + n * 1000).toISOString() : null;
}

/** Token perlu di-refresh kalau kedaluwarsa dalam withinMs (default 2 menit). */
export function needsRefresh(t: StoredToken, withinMs = 120_000, now = Date.now()): boolean {
  return !!t.expires_at && Date.parse(t.expires_at) - now <= withinMs;
}

export function requireScopes(granted: string | null | undefined, required: string[]): void {
  if (granted == null) return; // platform tidak mengembalikan daftar scope
  const have = new Set(granted.split(/[\s,]+/).filter(Boolean));
  const missing = required.filter((s) => !have.has(s));
  if (missing.length) throw new AdapterError("scope_missing", "izin yang dibutuhkan tidak diberikan", missing);
}

export const toInt = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) ? Math.trunc(n) : null;
};

export function chunk<T>(xs: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}
