// F-C18: ID (default) / EN tanpa prefix URL. Locale dari cookie NEXT_LOCALE yang berlaku di semua subdomain.
export const locales = ['id', 'en'] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = 'id';
export const LOCALE_COOKIE = 'NEXT_LOCALE';

/** Alasan standar penolakan (reason_code E-19) — satu daftar untuk brand, admin, clipper; teks di common.rejectReasons.<kode>. */
export const REJECT_REASONS = ['off_brief', 'missing_tags', 'low_quality', 'reused_content', 'wrong_account', 'sponsored_label', 'misleading',
  'inappropriate', 'fraud_suspected', 'other'] as const;
export type RejectReason = (typeof REJECT_REASONS)[number];

export function resolveLocale(value: string | undefined | null): Locale {
  return (locales as readonly string[]).includes(value ?? '') ? (value as Locale) : defaultLocale;
}

/** Gabungkan namespace pesan; nama file = namespace (messages/<locale>/<ns>.json). */
export async function loadMessages(locale: Locale, namespaces: readonly string[]): Promise<Record<string, unknown>> {
  const entries = await Promise.all(
    namespaces.map(async (ns) => [ns, (await import(`../messages/${locale}/${ns}.json`)).default] as const),
  );
  return Object.fromEntries(entries);
}

/**
 * Error fungsi api (message = kode mesin, mis. `not_eligible:need_social_account:tiktok`, `missing_tags:#mplid`,
 * `invalid:title`) → kunci namespace `errors` + parameter. Grup bertingkat: kunci `<grup>.<alasan>`.
 */
export function parseDbError(message: string | null | undefined): { key: string; param: string } {
  const [group = 'generic', ...rest] = (message ?? '').trim().split(':');
  const nested = ['not_eligible', 'auth', 'not_found', 'config'];
  if (nested.includes(group) && rest.length) return { key: `${group}.${rest[0]}`, param: rest.slice(1).join(':') };
  return { key: /^[a-z_]+$/.test(group) ? group : 'generic', param: rest.join(':') };
}
