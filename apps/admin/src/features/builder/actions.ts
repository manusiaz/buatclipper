'use server';

import { randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import type { BuilderActions, SaveResult } from '@clipper/campaign-builder';
import { dbError } from '@/lib/errors';
import { isUuid } from '@/lib/data';
import { assetPath, MAX_BYTES } from './paths';

/** F-A03: api.save_campaign atas nama org (admin_ops aal2). Draft managed + submit = kirim ke brand (invoice managed_service). */
export async function saveCampaign(payload: Record<string, unknown>, submit: boolean): Promise<SaveResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { data, error } = await db.rpc('save_campaign', { p_campaign: payload as never, p_submit: submit });
  if (error || !data) return { ok: false, error: dbError(error), detail: (error as { details?: string } | null)?.details ?? undefined };
  revalidatePath('/campaigns');
  return { ok: true, id: data };
}

/** Signed upload URL (aturan sama dengan brand): org diambil dari campaign di server, bukan dari browser. */
export async function campaignUploadUrl(input: Parameters<BuilderActions['uploadUrl']>[0]): ReturnType<BuilderActions['uploadUrl']> {
  await requireAdmin('admin_ops');
  const { campaignId, kind, filename, size } = input;
  if (!isUuid(campaignId) || !(kind in MAX_BYTES) || !(size > 0) || size > MAX_BYTES[kind]) return { ok: false, error: 'invalid:file' };
  const db = await coreServer('admin');
  const { data: c } = await db.from('campaigns').select('org_id').eq('id', campaignId).maybeSingle();
  if (!c?.org_id) return { ok: false, error: 'not_found:campaign' };
  const { bucket, path } = assetPath(kind, c.org_id, campaignId, filename, randomUUID().slice(0, 8));
  const { data, error } = await db.storage.from(bucket).createSignedUploadUrl(path);
  if (error || !data) return { ok: false, error: 'upload_failed' };
  return { ok: true, path: data.path, signedUrl: data.signedUrl };
}
