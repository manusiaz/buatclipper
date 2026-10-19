import { cache } from 'react';
import { cookies, headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { createServerClient } from '@supabase/ssr';
import { createCoreClient } from '@clipper/db-core';
import { cookieOptions, identityKey, identityUrl } from './cookies';
import {
  hasRole, hosts, isAdmin, loginUrl, onboardingUrl, securityUrl,
  type Claims, type PlatformRole, type SessionKind,
} from './index';

/** Client Auth identity untuk server (RSC, Server Action, route handler). Cookie ditulis lewat header (§15.6, R-17). */
export async function identityServer(kind: SessionKind = 'sso') {
  const store = await cookies();
  return createServerClient(identityUrl(), identityKey(), {
    cookieOptions: cookieOptions(kind),
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => store.set(name, value, options));
        } catch {
          // Dipanggil dari Server Component: cookie disegarkan proxy.ts, aman diabaikan.
        }
      },
    },
  });
}

/** Sesi terverifikasi (JWKS identity) per request. */
export const getAuth = cache(async (kind: SessionKind = 'sso') => {
  const supabase = await identityServer(kind);
  const { data } = await supabase.auth.getClaims();
  return { supabase, claims: (data?.claims ?? null) as Claims | null };
});

/** Client core dengan JWT identity (RLS core = user ini). */
export async function coreServer(kind: SessionKind = 'sso') {
  const { supabase } = await getAuth(kind);
  return createCoreClient(async () => (await supabase.auth.getSession()).data.session?.access_token ?? null);
}

/** Access token mentah untuk memanggil Edge Function dari server. */
export async function accessToken(kind: SessionKind = 'sso'): Promise<string | null> {
  const { supabase } = await getAuth(kind);
  return (await supabase.auth.getSession()).data.session?.access_token ?? null;
}

/** URL halaman saat ini (diset proxy.ts di header x-url). */
export async function currentUrl(): Promise<URL> {
  const h = await headers();
  return new URL(h.get('x-url') ?? '/', hosts.web);
}

type Guard = { claims: Claims };

/** accounts.{domain}: login wajib, sesi admin ditolak. */
export async function requireAccount(): Promise<Guard> {
  const { claims } = await getAuth('sso');
  const url = await currentUrl();
  if (!claims) redirect(`/login?next=${encodeURIComponent(url.pathname + url.search)}`);
  if (isAdmin(claims)) redirect(`${hosts.admin}/login`);
  return { claims };
}

/** app.{domain}: login (di origin app untuk PWA iOS) + consent clipper. */
export async function requireClipper(): Promise<Guard> {
  const { claims } = await getAuth('sso');
  const url = await currentUrl();
  if (!claims) redirect(`/login?next=${encodeURIComponent(url.pathname + url.search)}`);
  if (isAdmin(claims)) redirect(`${hosts.admin}/login`);
  if (!claims.consent_ok?.clipper) redirect(onboardingUrl('clipper', `${hosts.app}${url.pathname}${url.search}`));
  return { claims };
}

/** brand.{domain}: login di accounts + consent brand. */
export async function requireBrand(): Promise<Guard> {
  const { claims } = await getAuth('sso');
  const url = await currentUrl();
  const here = `${hosts.brand}${url.pathname}${url.search}`;
  if (!claims) redirect(loginUrl(here));
  if (isAdmin(claims)) redirect(`${hosts.admin}/login`);
  if (!claims.consent_ok?.brand) redirect(onboardingUrl('brand', here));
  return { claims };
}

/** Aksi yang menggerakkan uang brand (refund, rollover) butuh aal2 (§4). */
export async function requireBrandAal2(): Promise<Guard> {
  const g = await requireBrand();
  if (g.claims.aal !== 'aal2') {
    const url = await currentUrl();
    redirect(securityUrl(`${hosts.brand}${url.pathname}${url.search}`));
  }
  return g;
}

/** admin.{domain}: akun admin + aal2 + role. */
export async function requireAdmin(...roles: PlatformRole[]): Promise<Guard> {
  const { claims } = await getAuth('admin');
  if (!claims || !isAdmin(claims) || claims.aal !== 'aal2') redirect('/login');
  if (roles.length && !hasRole(claims, ...roles)) redirect('/?forbidden=1');
  return { claims };
}

export type FnResult<T> = { ok: true; data: T } | { ok: false; error: string; detail?: unknown; status: number };

/**
 * Panggil Edge Function dengan JWT sesi user (diverifikasi fungsi lewat JWKS identity). Menyatukan dua envelope:
 * core → body mentah / {error, message, detail}; identity → {ok, data} / {ok:false, error:{code, message}}.
 * brand & web hanya boleh project 'core' (dicek scripts/check-arch.mjs).
 */
export async function invokeFunction<T = unknown>(
  project: 'core' | 'identity',
  name: string,
  body: unknown,
  kind: SessionKind = 'sso',
): Promise<FnResult<T>> {
  const token = await accessToken(kind);
  if (!token) return { ok: false, error: 'auth:no_session', status: 401 };
  const [base, key] = project === 'core'
    ? [process.env.NEXT_PUBLIC_CORE_URL!, process.env.NEXT_PUBLIC_CORE_PUBLISHABLE_KEY!]
    : [process.env.NEXT_PUBLIC_IDENTITY_URL!, process.env.NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY!];
  let res: Response;
  try {
    res = await fetch(`${base}/functions/v1/${name}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: key },
      body: JSON.stringify(body),
      cache: 'no-store',
    });
  } catch {
    return { ok: false, error: 'network', status: 0 };
  }
  const json = (await res.json().catch(() => null)) as Record<string, unknown> | null;
  if (json && typeof json.ok === 'boolean') {
    if (json.ok) return { ok: true, data: json.data as T };
    const e = (json.error ?? {}) as { code?: string };
    return { ok: false, error: e.code ?? 'generic', status: res.status };
  }
  if (!res.ok) return { ok: false, error: String(json?.error ?? 'generic'), detail: json?.detail, status: res.status };
  return { ok: true, data: json as T };
}
