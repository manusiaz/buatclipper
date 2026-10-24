import { NextResponse, type NextRequest } from 'next/server';
import type { EmailOtpType } from '@supabase/supabase-js';
import { identityServer } from './server';
import { safeNext } from './index';

/** GET /auth/callback — tukar code PKCE (Google) jadi sesi, lalu ke next. */
export async function authCallback(request: NextRequest) {
  const url = request.nextUrl;
  const next = safeNext(url.searchParams.get('next'));
  const code = url.searchParams.get('code');
  if (code) {
    const supabase = await identityServer('sso');
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(next, request.url));
  }
  return NextResponse.redirect(new URL(`/login?error=oauth&next=${encodeURIComponent(next)}`, request.url));
}

/** GET /auth/confirm — link email berisi token_hash (template Invite user, paket managed). */
export async function authConfirm(request: NextRequest) {
  const url = request.nextUrl;
  const next = safeNext(url.searchParams.get('next'), '/');
  const tokenHash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type') as EmailOtpType | null;
  if (tokenHash && type) {
    const supabase = await identityServer('sso');
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
    if (!error) return NextResponse.redirect(new URL(next, request.url));
  }
  return NextResponse.redirect(new URL('/login?error=invalid_code', request.url));
}
