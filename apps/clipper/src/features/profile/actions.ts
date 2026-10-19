'use server';

import { revalidatePath } from 'next/cache';
import { requireClipper } from '@clipper/auth/server';
import { core, fail, ok, type Result } from '../lib/server';

const EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

/** Foto profil (F-C01, ≤ 1 MB): signed upload URL ke avatars/{uid}/<uuid>.<ext>; browser PUT langsung ke storage core. */
export async function avatarUploadUrl(mime: string): Promise<Result<{ signedUrl: string; path: string }>> {
  const { claims } = await requireClipper();
  const ext = EXT[mime];
  if (!ext) return fail('invalid:avatar_type');
  const db = await core();
  const { data, error } = await db.storage.from('avatars').createSignedUploadUrl(`${claims.sub}/${crypto.randomUUID()}.${ext}`);
  if (error || !data) return fail(error?.message);
  return ok({ signedUrl: data.signedUrl, path: data.path });
}

/** ensure_profile satu-satunya penulis avatar_path; username tetap, nama tampilan & foto diperbarui. */
export async function saveProfile(input: { displayName: string; avatarPath: string | null }): Promise<Result> {
  const { claims } = await requireClipper();
  const name = (input.displayName ?? '').trim();
  if (name.length < 1 || name.length > 50) return fail('invalid:display_name');
  if (input.avatarPath !== null && !input.avatarPath.startsWith(`${claims.sub}/`)) return fail('invalid:avatar_path');
  const db = await core();
  const { data: me } = await db.from('my_profile').select('username').maybeSingle();
  if (!me?.username) return fail('not_eligible:profile_missing');
  const { error } = await db.rpc('ensure_profile', {
    p_username: me.username,
    p_display_name: name,
    ...(input.avatarPath ? { p_avatar_path: input.avatarPath } : {}),
  });
  if (error) return fail(error.message);
  revalidatePath('/profile');
  revalidatePath('/', 'layout');
  return ok(null);
}
