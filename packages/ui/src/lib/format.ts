/**
 * Number / money / time formatting (Indonesian first). Pure functions — safe in server and client components.
 * Rules from DS 11: units always written (Rp, views, %), "Rp" glued to the number, tabular figures.
 */

export type UiLocale = 'id' | 'en';

const intlLocale = (locale: UiLocale = 'id') => (locale === 'en' ? 'en-US' : 'id-ID');

/** 1500000 → "1.500.000" (id) / "1,500,000" (en). */
export function formatNumber(value: number, locale: UiLocale = 'id', options?: Intl.NumberFormatOptions): string {
  return new Intl.NumberFormat(intlLocale(locale), { maximumFractionDigits: 0, ...options }).format(value);
}

/** 5_800_000 → "5,8 jt" (id) / "5.8M" (en). */
export function formatCompact(value: number, locale: UiLocale = 'id'): string {
  return new Intl.NumberFormat(intlLocale(locale), { notation: 'compact', maximumFractionDigits: 1 }).format(value);
}

/** 1500000 → "Rp1.500.000"; -83620 → "−Rp83.620"; compact → "Rp1,5 jt". */
export function formatIDR(
  value: number,
  options: { locale?: UiLocale; compact?: boolean; signed?: boolean; fractionDigits?: number } = {},
): string {
  const { locale = 'id', compact = false, signed = false, fractionDigits = 0 } = options;
  const abs = Math.abs(value);
  const body = compact
    ? formatCompact(abs, locale)
    : formatNumber(abs, locale, { minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits });
  const sign = value < 0 ? '−' : signed && value > 0 ? '+' : '';
  return `${sign}Rp${body}`;
}

/** Earning for a number of views at a rate per 1.000 views (IDR, rounded down to whole rupiah). */
export function earningFor(views: number, ratePer1k: number): number {
  return Math.floor((views / 1000) * ratePer1k);
}

const UNITS = [
  ['year', 365 * 24 * 3600],
  ['month', 30 * 24 * 3600],
  ['week', 7 * 24 * 3600],
  ['day', 24 * 3600],
  ['hour', 3600],
  ['minute', 60],
] as const;

const ID_UNIT: Record<(typeof UNITS)[number][0], string> = {
  year: 'tahun',
  month: 'bulan',
  week: 'minggu',
  day: 'hari',
  hour: 'jam',
  minute: 'menit',
};

/**
 * Relative time. id: "12 hari lagi", "3 jam lalu", "baru saja"; en: Intl ("in 12 days", "3 hours ago").
 * `now` is injectable so server and client can agree (see <RelativeTime>).
 */
export function formatRelative(target: Date | string | number, now: Date | number = Date.now(), locale: UiLocale = 'id'): string {
  const t = new Date(target).getTime();
  const n = typeof now === 'number' ? now : now.getTime();
  const diffSec = Math.round((t - n) / 1000);
  const abs = Math.abs(diffSec);
  if (abs < 45) return locale === 'en' ? 'just now' : 'baru saja';
  const [unit, size] = UNITS.find(([, s]) => abs >= s) ?? UNITS[UNITS.length - 1]!;
  const count = Math.max(1, Math.round(abs / size));
  if (locale === 'en') {
    return new Intl.RelativeTimeFormat('en', { numeric: 'auto' }).format(diffSec < 0 ? -count : count, unit);
  }
  return diffSec < 0 ? `${count} ${ID_UNIT[unit]} lalu` : `${count} ${ID_UNIT[unit]} lagi`;
}

/** Absolute date (DS: timeline uses absolute dates). "19 Okt 2026, 10.25". */
export function formatDateTime(
  value: Date | string | number,
  locale: UiLocale = 'id',
  options: Intl.DateTimeFormatOptions = { dateStyle: 'medium', timeStyle: 'short' },
): string {
  return new Intl.DateTimeFormat(intlLocale(locale), { timeZone: 'Asia/Jakarta', ...options }).format(new Date(value));
}

export function formatDate(value: Date | string | number, locale: UiLocale = 'id'): string {
  return formatDateTime(value, locale, { day: 'numeric', month: 'short', year: 'numeric' });
}

/** Remaining duration split into parts (for Countdown). Negative → all zero. */
export function durationParts(ms: number): { days: number; hours: number; minutes: number; seconds: number; totalHours: number } {
  const s = Math.max(0, Math.floor(ms / 1000));
  return {
    days: Math.floor(s / 86400),
    hours: Math.floor((s % 86400) / 3600),
    minutes: Math.floor((s % 3600) / 60),
    seconds: s % 60,
    totalHours: Math.floor(s / 3600),
  };
}

/** Initials for avatars: "Raka Pratama" → "RP", "@nara.gg" → "NA". */
export function initials(name: string): string {
  const clean = name.replace(/^@/, '').trim();
  const parts = clean.split(/[\s._-]+/).filter(Boolean);
  if (parts.length >= 2) return (parts[0]![0]! + parts[1]![0]!).toUpperCase();
  return clean.slice(0, 2).toUpperCase();
}
