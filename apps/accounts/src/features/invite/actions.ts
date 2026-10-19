'use server';

import { redirect } from 'next/navigation';
import { hosts } from '@clipper/auth';
import { coreServer, identityServer } from '@clipper/auth/server';
import { dbCode } from '@/lib/errors';

/** B2.2: accept_org_invite membuat profil dulu kalau belum ada, lalu keanggotaan org (alur 5). */
export async function acceptInvite(token: string): Promise<{ ok: true; redirect: string } | { ok: false; error: string }> {
  const core = await coreServer();
  const { error } = await core.rpc('accept_org_invite', { p_token: token });
  if (error) return { ok: false, error: dbCode(error) };
  return { ok: true, redirect: `${hosts.brand}/` };
}

/** "Bukan kamu?" — keluar lalu login lagi dengan akun lain, kembali ke undangan yang sama. */
export async function switchAccount(token: string): Promise<never> {
  const supabase = await identityServer('sso');
  await supabase.auth.signOut({ scope: 'local' });
  redirect(`/login?next=${encodeURIComponent(`/invite/${encodeURIComponent(token)}`)}`);
}
