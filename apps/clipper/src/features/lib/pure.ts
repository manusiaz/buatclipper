// Helper murni (tanpa React/Next) — dipakai server & client, dites vitest.
import { parseDbError } from '@clipper/i18n';

export const PLATFORM_ORDER = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'] as const;
export type PlatformId = (typeof PLATFORM_ORDER)[number];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === 'string' && UUID.test(v);
export const isPlatform = (v: unknown): v is PlatformId => typeof v === 'string' && (PLATFORM_ORDER as readonly string[]).includes(v);

/** numeric Postgres (number | string | null) → number. */
export function num(v: unknown): number {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : 0;
}

export function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

export function arr<T = unknown>(v: unknown): T[] {
  return Array.isArray(v) ? (v as T[]) : [];
}

export interface RateRule {
  kind: string;
  platform: string | null;
  reward_type_id: string;
  code?: string;
  unit_label?: string;
  decimals?: number;
  pool_id?: string;
  params: Record<string, unknown>;
}

/** Rate per 1.000 views satu rule (sama dengan market.rule_rate): per_1k_views → rate, tiered_cpm → tier pertama. */
export function ruleRate(rule: Pick<RateRule, 'kind' | 'params'>): number {
  if (rule.kind === 'per_1k_views') return num(rule.params?.rate);
  if (rule.kind === 'tiered_cpm') return num(arr<Record<string, unknown>>(rule.params?.tiers)[0]?.rate);
  return 0;
}

/** Rate per platform dalam Rupiah (nilai IDR per unit reward type) — angka besar di card F-C03. */
export function cardRates(rules: RateRule[], platforms: readonly string[], idrPerUnit: ReadonlyMap<string, number>) {
  return platforms
    .map((platform) => ({
      platform,
      ratePer1k: rules
        .filter((r) => r.platform === null || r.platform === platform)
        .reduce((sum, r) => sum + ruleRate(r) * (idrPerUnit.get(r.reward_type_id) ?? 0), 0),
    }))
    .filter((r) => r.ratePer1k > 0);
}

/** est_remaining_views {platform: views} → angka terbesar (pool yang paling lama habis). */
export function maxViews(est: unknown): number | undefined {
  if (!est || typeof est !== 'object') return undefined;
  const values = Object.values(est as Record<string, unknown>).map(num).filter((v) => v > 0);
  return values.length ? Math.max(...values) : undefined;
}

export function budgetUsedRatio(budget: unknown, remaining: unknown): number | undefined {
  const b = num(budget);
  if (b <= 0) return undefined;
  return Math.min(1, Math.max(0, 1 - num(remaining) / b));
}

const DAY = 86_400_000;

/**
 * Perkiraan earning Pending → Tersedia: lock (locked_at, atau posted_at + view window) + hold. hold = finance.hold_days
 * (bukan public.*, tidak terbaca clipper) → default PRD 7 hari.
 */
export function estimateRelease(
  s: { locked_at: string | null; posted_at: string | null; created_at: string },
  viewWindowDays: number,
  holdDays = 7,
): Date {
  const lock = s.locked_at
    ? new Date(s.locked_at).getTime()
    : new Date(s.posted_at ?? s.created_at).getTime() + viewWindowDays * DAY;
  return new Date(lock + holdDays * DAY);
}

/** Batch mingguan (D-05) = Senin berikutnya (WIB). Perkiraan; jadwal pasti ditentukan tim finance. */
export function nextBatchDate(now: Date = new Date()): Date {
  const wib = new Date(now.getTime() + 7 * 3_600_000);
  const day = wib.getUTCDay();
  const add = ((8 - day) % 7) || 7;
  const target = Date.UTC(wib.getUTCFullYear(), wib.getUTCMonth(), wib.getUTCDate() + add, 3); // 10.00 WIB
  return new Date(target);
}

/** Kode error (RPC / Edge Function) → kunci namespace errors + parameter teks. */
export function errorKey(raw: string | null | undefined, detail?: unknown, platformName: (p: string) => string = (p) => p) {
  const { key, param } = parseDbError(raw);
  if (key === 'missing_tags') {
    const list = Array.isArray(detail) ? detail.map(String) : param ? param.split(',') : [];
    return { key, param: list.map((x) => x.trim()).filter(Boolean).join(', ') };
  }
  if (key === 'not_eligible.need_social_account') return { key, param: platformName(param) };
  return { key, param };
}

/** Bandingkan string tanpa bocor waktu (state OAuth). */
export function safeEqual(a: string, b: string): boolean {
  if (typeof a !== 'string' || typeof b !== 'string' || !a || !b) return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

/** Hanya URL https (link dari config / payload). */
export function httpsUrl(v: unknown): string | null {
  if (typeof v !== 'string' || v.length > 2000) return null;
  try {
    const u = new URL(v);
    return u.protocol === 'https:' ? u.toString() : null;
  } catch {
    return null;
  }
}

/** public.community.links {discord, whatsapp, …} → link https yang terisi (F-C19). */
export function communityLinks(value: unknown): { key: string; href: string }[] {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return [];
  return Object.entries(value as Record<string, unknown>)
    .map(([key, v]) => ({ key, href: httpsUrl(v) }))
    .filter((x): x is { key: string; href: string } => !!x.href);
}

/** public.flags.platforms → platform yang aktif, urutan tetap. */
export function enabledPlatforms(flags: unknown): PlatformId[] {
  const f = flags && typeof flags === 'object' ? (flags as Record<string, unknown>) : {};
  return PLATFORM_ORDER.filter((p) => f[p] === true);
}

/** Video dari API platform: thumbnail hanya https. */
export function safeThumb(v: unknown): string | null {
  return httpsUrl(v);
}

export interface RecipientField {
  key: string;
  label: string;
  pii: boolean;
  required: boolean;
}

/** recipient_schema reward type [{key, label, pii, required}] → field rapi (required default true, sama dengan SQL). */
export function recipientFields(schema: unknown): RecipientField[] {
  return arr<Record<string, unknown>>(schema)
    .filter((f) => typeof f?.key === 'string' && f.key)
    .map((f) => ({
      key: String(f.key),
      label: typeof f.label === 'string' && f.label ? f.label : String(f.key),
      pii: f.pii === true || f.pii === 'true',
      required: f.required === undefined ? true : f.required === true || f.required === 'true',
    }));
}

/** VAPID public key (base64url) → Uint8Array untuk pushManager.subscribe. */
export function base64UrlToBytes(input: string): Uint8Array<ArrayBuffer> {
  const pad = '='.repeat((4 - (input.length % 4)) % 4);
  const raw = atob((input + pad).replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

/** Status submisi (S-03) → kelompok di Tugas Saya (F-C07). */
export type TaskGroup = 'validating' | 'review' | 'tracking' | 'rejected' | 'appeal' | 'locked';
export function taskGroup(status: string): TaskGroup {
  switch (status) {
    case 'validating':
      return 'validating';
    case 'in_review':
      return 'review';
    case 'tracking':
    case 'flagged':
      return 'tracking';
    case 'appealed':
      return 'appeal';
    case 'locked':
    case 'settled':
      return 'locked';
    default:
      return 'rejected'; // rejected, rejected_final, forfeited
  }
}
