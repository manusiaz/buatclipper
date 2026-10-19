// F-C18: ID (default) / EN tanpa prefix URL. Locale dari cookie NEXT_LOCALE yang berlaku di semua subdomain.
export const locales = ['id', 'en'] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = 'id';
export const LOCALE_COOKIE = 'NEXT_LOCALE';

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
