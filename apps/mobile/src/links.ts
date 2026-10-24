// URL web (app.{domain}/…) → rute app native bila ada padanannya; null = buka di browser.
import { env } from './env';

export function nativeRoute(href: string): string | null {
  const path = href.startsWith('/') ? href : href.startsWith(env.appUrl) ? href.slice(env.appUrl.length) || '/' : null;
  if (!path) return null;
  const [base, query] = path.split('?') as [string, string | undefined];
  const q = query ? `?${query}` : '';
  const m = base.match(/^\/campaigns\/([0-9a-f-]{36})$/);
  if (m) return `/campaign/${m[1]}${q}`;
  if (base === '/tasks') return `/clips${q}`;
  if (base === '/wallet/withdraw') return `/withdraw${q}`;
  if (/^\/(wallet|social|notifications|profile|leaderboard|referral|settings|share)$/.test(base)) return base + q;
  return base === '/campaigns' || base === '/' ? '/' : null;
}

/** href tanpa padanan native → URL yang bisa dibuka browser (path relatif notifikasi = halaman app.{domain}). */
export const webHref = (href: string) => (href.startsWith('/') ? env.appUrl + href : href);
