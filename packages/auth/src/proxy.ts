import { NextResponse, type NextRequest } from 'next/server';
import { createServerClient } from '@supabase/ssr';
import { cookieOptions, identityKey, identityUrl } from './cookies';
import { hosts, isAdmin, loginUrl, onboardingUrl, type Claims } from './index';

export type ProxyApp = 'web' | 'accounts' | 'clipper' | 'brand' | 'admin';

const EMBEDS = [
  'https://www.tiktok.com', 'https://www.instagram.com', 'https://www.youtube.com', 'https://www.youtube-nocookie.com',
  'https://www.threads.net', 'https://www.facebook.com', 'https://platform.twitter.com',
];

/** CSP ber-nonce per request (R-16): hanya script milik sendiri + Turnstile; frame hanya embed resmi platform. */
export function buildCsp(nonce: string): string {
  const dev = process.env.NODE_ENV !== 'production';
  const supabase = [process.env.NEXT_PUBLIC_IDENTITY_URL, process.env.NEXT_PUBLIC_CORE_URL]
    .filter((u): u is string => !!u)
    .map((u) => new URL(u).origin);
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' https://challenges.cloudflare.com${dev ? " 'unsafe-eval'" : ''}`,
    "style-src 'self' 'unsafe-inline'",
    // Origin Supabase eksplisit: storage lokal (http://127.0.0.1) tidak tercakup https:.
    `img-src 'self' data: blob: https: ${supabase.join(' ')}`,
    "font-src 'self' data:",
    `connect-src 'self' ${supabase.join(' ')}${dev ? ' ws: wss:' : ''}`,
    `frame-src https://challenges.cloudflare.com ${EMBEDS.join(' ')}`,
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    dev ? '' : 'upgrade-insecure-requests',
  ].filter(Boolean).join('; ');
}

/**
 * proxy.ts tiap app: CSP + segarkan sesi di server (cookie lewat header, WebKit membatasi cookie JS 7 hari) +
 * gate login/consent/admin sesuai §6.7. `publicPaths` = prefix yang boleh tanpa login.
 */
export async function clipperProxy(request: NextRequest, app: ProxyApp, publicPaths: string[] = []) {
  const nonce = btoa(crypto.randomUUID());
  const csp = buildCsp(nonce);
  const reqHeaders = new Headers(request.headers);
  reqHeaders.set('x-nonce', nonce);
  reqHeaders.set('x-url', request.nextUrl.href);
  reqHeaders.set('content-security-policy', csp);

  let response = NextResponse.next({ request: { headers: reqHeaders } });
  const done = (res: NextResponse) => {
    res.headers.set('Content-Security-Policy', csp);
    return res;
  };
  // {domain} tidak menyentuh identity sama sekali (invarian 1): cukup CSP.
  if (app === 'web') return done(response);

  const kind = app === 'admin' ? 'admin' : 'sso';
  const supabase = createServerClient(identityUrl(), identityKey(), {
    cookieOptions: cookieOptions(kind),
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list, extra) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        reqHeaders.set('cookie', request.cookies.toString());
        response = NextResponse.next({ request: { headers: reqHeaders } });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        Object.entries(extra ?? {}).forEach(([k, v]) => response.headers.set(k, v));
      },
    },
  });
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as Claims | null;

  const path = request.nextUrl.pathname;
  const here = path + request.nextUrl.search;
  const redirect = (to: string) => {
    const res = NextResponse.redirect(new URL(to, request.url));
    response.cookies.getAll().forEach((c) => res.cookies.set(c));
    return done(res);
  };
  if (publicPaths.some((p) => path === p || path.startsWith(p.endsWith('/') ? p : `${p}/`))) return done(response);

  if (!claims) {
    if (app === 'brand') return redirect(loginUrl(`${hosts.brand}${here}`));
    return redirect(`/login?next=${encodeURIComponent(here)}`);
  }
  if (app === 'admin') {
    return !isAdmin(claims) || claims.aal !== 'aal2' ? redirect('/login') : done(response);
  }
  if (isAdmin(claims)) {
    await supabase.auth.signOut({ scope: 'local' });
    return redirect(`${hosts.admin}/login`);
  }
  if (app === 'clipper' && !claims.consent_ok?.clipper) return redirect(onboardingUrl('clipper', `${hosts.app}${here}`));
  if (app === 'brand' && !claims.consent_ok?.brand) return redirect(onboardingUrl('brand', `${hosts.brand}${here}`));
  return done(response);
}

