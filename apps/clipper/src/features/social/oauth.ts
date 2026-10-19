// OAuth sosmed (C1.5): state anti-CSRF + code_verifier PKCE di cookie httpOnly 10 menit, path /api/oauth.
import { hosts, safeNext } from '@clipper/auth';
import { safeEqual } from '../lib/pure';

export const STATE_COOKIE = 'clipper-oauth';
export const STATE_MAX_AGE = 600;

export interface OAuthState {
  state: string;
  verifier?: string;
  platform: string;
  next?: string;
  pageId?: string;
}

export const redirectUri = (platform: string) => `${hosts.app}/api/oauth/${platform}/callback`;

export const cookieOptions = () => ({
  httpOnly: true,
  sameSite: 'lax' as const,
  secure: hosts.app.startsWith('https://'),
  path: '/api/oauth',
  maxAge: STATE_MAX_AGE,
});

export function encodeState(s: OAuthState): string {
  return Buffer.from(JSON.stringify(s)).toString('base64url');
}

export function decodeState(raw: string | undefined): OAuthState | null {
  if (!raw) return null;
  try {
    const v = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as OAuthState;
    return typeof v?.state === 'string' && typeof v.platform === 'string' ? v : null;
  } catch {
    return null;
  }
}

/** state dari platform harus sama persis dengan cookie (constant-time) dan platform-nya cocok. */
export function verifyState(saved: OAuthState | null, platform: string, returned: string | null): saved is OAuthState {
  return !!saved && saved.platform === platform && safeEqual(saved.state, returned ?? '');
}

/** next hanya path internal app (setelah connect kembali ke campaign). */
export function internalNext(next: string | null | undefined): string | undefined {
  if (!next) return undefined;
  const n = safeNext(next, '');
  return n.startsWith('/') ? n : undefined;
}
