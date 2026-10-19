'use server';

import { redirect } from 'next/navigation';
import { getAuth, identityServer } from './server';
import { hosts, isAdmin, safeNext, type Claims, type SessionKind } from './index';

export type AuthResult =
  | { ok: true; redirect?: string; step?: 'mfa_enroll' | 'mfa_challenge' }
  | { ok: false; error: string };

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function mapError(e: { code?: string; status?: number; message?: string } | null): string {
  const code = e?.code ?? '';
  if (code.includes('rate_limit') || e?.status === 429) return 'rate_limited';
  if (code.includes('captcha')) return 'captcha';
  if (code === 'otp_expired' || code === 'invalid_credentials' || code === 'bad_jwt') return 'invalid_code';
  if (code === 'mfa_verification_failed') return 'mfa_invalid';
  return 'generic';
}

/** Kirim kode OTP (template Magic Link Auth identity berisi {{ .Token }}, §15.10). */
export async function sendOtp(kind: SessionKind, email: string, captchaToken?: string): Promise<AuthResult> {
  if (!EMAIL.test(email)) return { ok: false, error: 'invalid_email' };
  const supabase = await identityServer(kind);
  const { error } = await supabase.auth.signInWithOtp({
    email: email.trim().toLowerCase(),
    options: { shouldCreateUser: kind === 'sso', captchaToken },
  });
  return error ? { ok: false, error: mapError(error) } : { ok: true };
}

/** Verifikasi OTP di server → cookie sesi diset lewat header. Admin & non-admin dipisah (§6.7, §15.6). */
export async function verifyOtp(kind: SessionKind, email: string, token: string, next?: string): Promise<AuthResult> {
  const supabase = await identityServer(kind);
  const { data, error } = await supabase.auth.verifyOtp({ email: email.trim().toLowerCase(), token: token.trim(), type: 'email' });
  if (error || !data.session) return { ok: false, error: mapError(error) };
  const claims = (await supabase.auth.getClaims()).data?.claims as Pick<Claims, 'app_roles'> | undefined;
  const admin = isAdmin(claims);
  if (kind === 'sso' && admin) {
    await supabase.auth.signOut({ scope: 'local' });
    return { ok: false, error: 'admin_elsewhere' };
  }
  if (kind === 'admin') {
    if (!admin) {
      await supabase.auth.signOut({ scope: 'local' });
      return { ok: false, error: 'admin_only' };
    }
    const { data: f } = await supabase.auth.mfa.listFactors();
    return { ok: true, step: f?.totp?.some((x) => x.status === 'verified') ? 'mfa_challenge' : 'mfa_enroll' };
  }
  return { ok: true, redirect: safeNext(next) };
}

/** Google lewat Auth identity (PKCE; code verifier di cookie server). origin = host app yang memanggil. */
export async function googleSignIn(origin: string, next?: string): Promise<AuthResult> {
  const allowed = [hosts.accounts, hosts.app].map((h) => new URL(h).origin);
  if (!allowed.includes(new URL(origin).origin)) return { ok: false, error: 'generic' };
  const supabase = await identityServer('sso');
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo: `${origin}/auth/callback?next=${encodeURIComponent(safeNext(next))}`, skipBrowserRedirect: true },
  });
  return error || !data.url ? { ok: false, error: 'oauth' } : { ok: true, redirect: data.url };
}

export async function signOut(kind: SessionKind): Promise<never> {
  const supabase = await identityServer(kind);
  await supabase.auth.signOut({ scope: 'local' });
  redirect(kind === 'admin' ? `${hosts.admin}/login` : `${hosts.web}/`);
}

/** Mulai pendaftaran TOTP: QR (SVG data URL) + secret untuk input manual. */
export async function mfaEnroll(kind: SessionKind): Promise<{ ok: true; factorId: string; qr: string; secret: string } | { ok: false; error: string }> {
  const { supabase, claims } = await getAuth(kind);
  if (!claims) return { ok: false, error: 'generic' };
  const { data: existing } = await supabase.auth.mfa.listFactors();
  // Faktor TOTP yang belum diverifikasi dari percobaan sebelumnya dibuang supaya enroll baru tidak bentrok.
  for (const f of existing?.all ?? []) {
    if (f.factor_type === 'totp' && f.status !== 'verified') await supabase.auth.mfa.unenroll({ factorId: f.id });
  }
  const { data, error } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: `totp-${Date.now()}` });
  if (error || !data) return { ok: false, error: mapError(error) };
  return { ok: true, factorId: data.id, qr: data.totp.qr_code, secret: data.totp.secret };
}

/** Verifikasi kode TOTP → sesi naik ke aal2. factorId kosong = faktor terverifikasi pertama. */
export async function mfaVerify(kind: SessionKind, code: string, factorId?: string, next?: string): Promise<AuthResult> {
  const supabase = await identityServer(kind);
  let id = factorId;
  if (!id) {
    const { data } = await supabase.auth.mfa.listFactors();
    id = data?.totp?.find((f) => f.status === 'verified')?.id;
  }
  if (!id) return { ok: false, error: 'mfa_invalid' };
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: id, code: code.trim() });
  if (error) return { ok: false, error: mapError(error) };
  return { ok: true, redirect: kind === 'admin' ? '/' : safeNext(next, `${hosts.accounts}/security`) };
}

/** Status MFA untuk halaman keamanan. */
export async function mfaStatus(kind: SessionKind): Promise<{ enrolled: boolean; aal: string | null }> {
  const { supabase } = await getAuth(kind);
  const [{ data: f }, { data: a }] = await Promise.all([
    supabase.auth.mfa.listFactors(),
    supabase.auth.mfa.getAuthenticatorAssuranceLevel(),
  ]);
  return { enrolled: !!f?.totp?.some((x) => x.status === 'verified'), aal: a?.currentLevel ?? null };
}

/** Setelah consent/KYC berubah, claim JWT baru berlaku setelah refresh (§15.6). */
export async function refreshSession(kind: SessionKind = 'sso'): Promise<void> {
  const supabase = await identityServer(kind);
  await supabase.auth.refreshSession();
}
