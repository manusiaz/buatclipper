import { coreServer } from '@clipper/auth/server';

/** public.community.links.support (core, terbaca anon) → link https kontak bantuan; selain https → null. */
export async function supportUrl(): Promise<string | null> {
  const db = await coreServer();
  const { data } = await db.from('settings').select('value').eq('key', 'public.community.links').maybeSingle();
  const v = (data?.value as Record<string, unknown> | null)?.support;
  return typeof v === 'string' && /^https:\/\/\S+$/.test(v) ? v : null;
}
