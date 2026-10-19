'use server';

import { cookies } from 'next/headers';
import { safeNext } from '@clipper/auth';
import { refreshSession } from '@clipper/auth/actions';
import { coreServer, getAuth } from '@clipper/auth/server';
import { dbCode } from '@/lib/errors';
import { identityDb } from '@/lib/identity';
import { DISPLAY_NAME_MAX, normalizeUsername, USERNAME_RE, usernameCandidates, type Role } from './rules';

export type UsernameCheck = { status: 'ok' | 'taken' | 'invalid'; suggestions: string[] };

/** Cek unik saat diketik (C1.3). Username milik sendiri dianggap tersedia. */
export async function checkUsername(raw: string): Promise<UsernameCheck> {
  const username = normalizeUsername(raw);
  if (!USERNAME_RE.test(username)) return { status: 'invalid', suggestions: [] };
  const [{ claims }, core] = await Promise.all([getAuth('sso'), coreServer()]);
  const candidates = usernameCandidates(username);
  const { data } = await core.from('profiles').select('id, username').in('username', [username, ...candidates]);
  const taken = new Set((data ?? []).filter((p) => p.id !== claims?.sub).map((p) => p.username));
  if (!taken.has(username)) return { status: 'ok', suggestions: [] };
  return { status: 'taken', suggestions: candidates.filter((c) => !taken.has(c)).slice(0, 3) };
}

export interface OnboardingInput {
  role: Role;
  username: string;
  displayName: string;
  tosVersion: string;
  privacyVersion: string;
  adult: boolean;
  /** Tujuan setelah selesai (sudah dihitung halaman; divalidasi ulang safeNext). */
  dest: string;
}

export type OnboardingResult = { ok: true; redirect: string } | { ok: false; error: string };

/**
 * Urutan §15.6 / C1.3: ensure_profile (core) → record_consent (identity) → refreshSession. Consent paling akhir: gagal di
 * tengah = claim consent_ok tetap false, user kembali ke onboarding, tidak pernah masuk app tanpa profil.
 */
export async function completeOnboarding(input: OnboardingInput): Promise<OnboardingResult> {
  const { claims } = await getAuth('sso');
  if (!claims) return { ok: false, error: 'auth:no_session' };
  const username = normalizeUsername(input.username);
  const displayName = input.displayName.trim();
  if (!USERNAME_RE.test(username)) return { ok: false, error: 'username_invalid' };
  if (!displayName || displayName.length > DISPLAY_NAME_MAX) return { ok: false, error: 'display_name_invalid' };
  if (input.role === 'clipper' && !input.adult) return { ok: false, error: 'age_required' };

  // Kode referral dari cookie .{domain} (F-C16); ensure_profile hanya memakainya untuk profil baru.
  const ref = input.role === 'clipper' ? (await cookies()).get('clipper_ref')?.value?.toLowerCase() : undefined;
  const core = await coreServer();
  const { error: profileError } = await core.rpc('ensure_profile', {
    p_username: username,
    p_display_name: displayName,
    p_referral_code: ref && /^[a-z0-9]{8}$/.test(ref) ? ref : undefined,
  });
  if (profileError) {
    const inactive = profileError.code === '42501' && /aktif/.test(profileError.message);
    return {
      ok: false,
      error: inactive
        ? 'not_eligible:profile_inactive'
        : dbCode(profileError, { '23505': 'username_taken', '23514': 'username_invalid' }),
    };
  }

  const id = await identityDb();
  const consents =
    input.role === 'clipper'
      ? ([['tos_clipper', input.tosVersion], ['privacy', input.privacyVersion], ['age_18_plus', undefined]] as const)
      : ([['tos_brand', input.tosVersion], ['privacy', input.privacyVersion]] as const);
  const results = await Promise.all(consents.map(([kind, version]) => id.rpc('record_consent', { p_kind: kind, p_version: version })));
  const failed = results.find((r) => r.error)?.error;
  if (failed) return { ok: false, error: dbCode(failed, { '22023': 'legal_outdated' }) };

  await refreshSession('sso');
  return { ok: true, redirect: safeNext(input.dest) };
}
