export * from './core';
import type { Locale } from './core';

/** Gabungkan namespace pesan; nama file = namespace (messages/<locale>/<ns>.json). */
export async function loadMessages(locale: Locale, namespaces: readonly string[]): Promise<Record<string, unknown>> {
  const entries = await Promise.all(
    namespaces.map(async (ns) => [ns, (await import(`../messages/${locale}/${ns}.json`)).default] as const),
  );
  return Object.fromEntries(entries);
}
