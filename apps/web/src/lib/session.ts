import { cookies } from 'next/headers';
import { hosts, loginUrl } from '@clipper/auth';

/** Cookie sesi SSO .{domain} ada? Hanya dicek keberadaannya, tidak pernah dibaca ({domain} tidak menyentuh identity). */
export async function hasSession(): Promise<boolean> {
  const jar = await cookies();
  return jar.has('clipper-auth') || jar.has('clipper-auth.0');
}

/** CTA clipper (§6.8): sudah ada sesi → langsung ke app, belum → login accounts dengan next ke app. */
export const clipperHref = (session: boolean, path = '/campaigns') =>
  session ? `${hosts.app}${path}` : loginUrl(`${hosts.app}${path}`);

/** CTA brand (B1.1): login accounts dengan next=brand/new. */
export const brandHref = (session: boolean) => (session ? `${hosts.brand}/new` : loginUrl(`${hosts.brand}/new`));
