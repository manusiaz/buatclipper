'use server';

import { revalidatePath } from 'next/cache';
import { hosts } from '@clipper/auth';
import { refreshSession } from '@clipper/auth/actions';
import { identityServer, invokeFunction } from '@clipper/auth/server';
import { dbCode } from '@/lib/errors';
import { identityDb } from '@/lib/identity';
import { CONSENT_KINDS, type ConsentKind } from './consents';

// ToS/privasi/umur diberikan ulang lewat onboarding (dokumen versi terbaru harus ditampilkan dulu).
const GRANTABLE: ConsentKind[] = ['share_with_brand', 'kyc'];

/** C2.4: cabut consent (semua jenis) atau beri ulang share_with_brand / kyc. Claim consent_ok ikut diperbarui. */
export async function setConsent(kind: ConsentKind, granted: boolean): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!CONSENT_KINDS.includes(kind) || (granted && !GRANTABLE.includes(kind))) return { ok: false, error: 'invalid_input' };
  const id = await identityDb();
  const { error } = await id.rpc('record_consent', { p_kind: kind, p_granted: granted });
  if (error) return { ok: false, error: dbCode(error) };
  await refreshSession('sso');
  revalidatePath('/', 'layout');
  return { ok: true };
}

/** Alur 7 lewat identity delete-account (core close_account menolak kalau saldo/payout masih berjalan). */
export async function deleteAccount(): Promise<{ ok: true; redirect: string } | { ok: false; error: string }> {
  const r = await invokeFunction('identity', 'delete-account', { confirm: true });
  if (!r.ok) return { ok: false, error: r.error };
  const supabase = await identityServer('sso');
  await supabase.auth.signOut({ scope: 'local' });
  return { ok: true, redirect: `${hosts.web}/?deleted=1` };
}
