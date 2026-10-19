import type { CookieOptionsWithName } from '@supabase/ssr';
import type { SessionKind } from './index';

const secure = (process.env.NEXT_PUBLIC_ACCOUNTS_URL ?? '').startsWith('https://');

/**
 * sso: satu cookie Domain=.{domain} untuk accounts, app, brand (§15.6). admin: host-only, nama lain.
 * httpOnly: sesi tidak pernah dibaca JavaScript — semua akses data lewat server (RSC, Server Action, route handler),
 * jadi XSS di satu subdomain tidak bisa mencuri token (R-16). Upload besar memakai signed upload URL dari server.
 */
export function cookieOptions(kind: SessionKind): CookieOptionsWithName {
  return kind === 'admin'
    ? { name: 'clipper-admin-auth', path: '/', sameSite: 'strict', secure, httpOnly: true }
    : { name: 'clipper-auth', domain: process.env.NEXT_PUBLIC_COOKIE_DOMAIN, path: '/', sameSite: 'lax', secure, httpOnly: true };
}

export const identityUrl = () => process.env.NEXT_PUBLIC_IDENTITY_URL!;
export const identityKey = () => process.env.NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY!;
