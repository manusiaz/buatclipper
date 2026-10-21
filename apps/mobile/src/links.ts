// URL web (app.{domain}/…) → rute app native bila ada padanannya; null = buka di browser.
import { env } from './env';

export function nativeRoute(href: string): string | null {
  const path = href.startsWith('/') ? href : href.startsWith(env.appUrl) ? href.slice(env.appUrl.length) || '/' : null;
  if (!path) return null;
  const m = path.match(/^\/campaigns\/([0-9a-f-]{36})/);
  if (m) return `/campaign/${m[1]}`;
  if (/^\/(tasks|wallet|social|notifications)(\?|$)/.test(path)) return path.split('?')[0]!;
  return path === '/campaigns' || path === '/' ? '/' : null;
}
