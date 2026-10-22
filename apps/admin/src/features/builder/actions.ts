'use server';

import { randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { brandServer, coreServer, requireAdmin } from '@clipper/auth/server';
import { persistCampaign, type BuilderActions, type SaveResult } from '@clipper/campaign-builder';
import { dbError } from '@/lib/errors';
import { isUuid } from '@/lib/data';
import { assetPath, MAX_BYTES } from './paths';

/**
 * F-A03: builder atas nama org (admin_ops aal2): isi ke project brand, jadwal/pool/rule/fee ke admin (persistCampaign).
 * Draft managed + submit = kirim ke brand (invoice managed_service).
 */
export async function saveCampaign(payload: Record<string, unknown>, submit: boolean): Promise<SaveResult> {
  await requireAdmin('admin_ops');
  const [core, brand] = await Promise.all([coreServer('admin'), brandServer('admin')]);
  const r = await persistCampaign({ brand, core }, payload, submit);
  if (!r.ok) return { ...r, error: dbError({ message: r.error }) };
  revalidatePath('/campaigns');
  return r;
}

/** Signed upload URL (aturan sama dengan brand): org diambil dari campaign di server, bukan dari browser. */
export async function campaignUploadUrl(input: Parameters<BuilderActions['uploadUrl']>[0]): ReturnType<BuilderActions['uploadUrl']> {
  await requireAdmin('admin_ops');
  const { campaignId, kind, filename, size } = input;
  if (!isUuid(campaignId) || !(kind in MAX_BYTES) || !(size > 0) || size > MAX_BYTES[kind]) return { ok: false, error: 'invalid:file' };
  const db = await brandServer('admin');
  const { data: c } = await db.from('campaigns').select('org_id').eq('id', campaignId).maybeSingle();
  if (!c?.org_id) return { ok: false, error: 'not_found:campaign' };
  const { bucket, path } = assetPath(kind, c.org_id, campaignId, filename, randomUUID().slice(0, 8));
  const { data, error } = await db.storage.from(bucket).createSignedUploadUrl(path);
  if (error || !data) return { ok: false, error: 'upload_failed' };
  return { ok: true, path: data.path, signedUrl: data.signedUrl };
}
