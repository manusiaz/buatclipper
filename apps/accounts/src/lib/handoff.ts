import { safeNext } from '@clipper/auth';
import type { FnResult } from '@clipper/auth/server';

/** Hasil redeem identity session-handoff: token_hash magic link + next yang disimpan saat kode dibuat. */
export type Redeemed = { token_hash?: unknown; next?: unknown };

export interface HandoffDeps {
  redeem: (code: string) => Promise<FnResult<Redeemed>>;
  /** verifyOtp magiclink di client SSO server (cookie .{domain}); true = sesi tersimpan. */
  verify: (tokenHash: string) => Promise<boolean>;
}

const CODE = /^[A-Za-z0-9_-]{43}$/;

/**
 * Tujuan redirect /handoff. Sukses → next dari identity (lewat safeNext). Gagal apa pun (kode salah/terpakai/kedaluwarsa,
 * jaringan, verifyOtp) → /login?next=… tanpa alasan; `hint` = next dari URL, hanya untuk balik setelah login manual.
 */
export async function handoffTarget(code: string | null, hint: string | null, deps: HandoffDeps): Promise<string> {
  const fail = `/login?next=${encodeURIComponent(safeNext(hint))}`;
  if (!code || !CODE.test(code)) return fail;
  try {
    const r = await deps.redeem(code);
    if (!r.ok || typeof r.data?.token_hash !== 'string' || typeof r.data.next !== 'string') return fail;
    return (await deps.verify(r.data.token_hash)) ? safeNext(r.data.next) : fail;
  } catch {
    return fail;
  }
}
