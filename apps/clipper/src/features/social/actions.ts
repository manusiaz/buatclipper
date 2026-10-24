'use server';

import { revalidatePath } from 'next/cache';
import { invokeFunction, requireClipper } from '@clipper/auth/server';
import { fail, ok, type Result } from '../lib/server';

const ref = (channel: string) => (channel ?? '').trim().slice(0, 200);

/** D-11 fallback: kode verifikasi untuk dipasang di deskripsi channel YouTube. */
export async function youtubeCode(channel: string): Promise<Result<{ handle: string; code: string }>> {
  await requireClipper();
  if (!ref(channel)) return fail('bad_channel');
  const r = await invokeFunction<{ handle: string; code: string }>('creator', 'social', { action: 'youtube_code', channel: ref(channel) });
  if (!r.ok) return fail(r.error, r.detail);
  return ok({ handle: String(r.data.handle), code: String(r.data.code) });
}

export async function youtubeVerify(channel: string): Promise<Result<{ handle: string }>> {
  await requireClipper();
  if (!ref(channel)) return fail('bad_channel');
  const r = await invokeFunction<{ handle: string }>('creator', 'social', { action: 'youtube_verify', channel: ref(channel) });
  if (!r.ok) return fail(r.error, r.detail);
  revalidatePath('/social');
  return ok({ handle: String(r.data.handle) });
}
