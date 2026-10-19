'use server';

import { randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import type { SaveResult } from '@clipper/campaign-builder';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

/** F-B10 duplikat / simpan sebagai template (hasil selalu draft). */
export async function duplicateCampaign(orgId: string, campaignId: string, asTemplate: boolean): Promise<Result<{ id: string }>> {
  const { core } = await getOrgContext(orgId);
  const { data, error } = await core.rpc('duplicate_campaign', { p_campaign: campaignId, p_as_template: asTemplate });
  if (error || !data) return fail(error);
  revalidatePath(`/${orgId}/campaigns`);
  return { ok: true, id: data };
}

/**
 * Builder: api.save_campaign(p_campaign, p_submit). Sengaja tanpa revalidatePath: revalidasi di action merender ulang
 * halaman builder yang sedang diedit (autosave); halaman lain dinamis dan dimuat segar saat dibuka.
 */
export async function saveCampaign(orgId: string, payload: Record<string, unknown>, submit: boolean): Promise<SaveResult> {
  const { core } = await getOrgContext(orgId);
  const body = payload.id ? payload : { ...payload, org_id: orgId };
  const { data, error } = await core.rpc('save_campaign', { p_campaign: body as never, p_submit: submit });
  if (error || !data) return { ok: false, error: error?.message || 'generic', detail: error?.details || undefined };
  return { ok: true, id: data };
}

const safeName = (name: string) =>
  name.toLowerCase().normalize('NFKD').replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(-80) || 'file';

/**
 * Signed upload URL (storage core, policy campaign_files_write): cover → campaign-covers/{org}/{campaign}/…,
 * aset → campaign-assets/{org}/{campaign}/…, brief mentah → campaign-assets/{org}/{campaign}/internal/…
 */
export async function campaignUploadUrl(
  orgId: string,
  input: { campaignId: string; kind: 'cover' | 'asset' | 'internal'; filename: string; contentType: string; size: number },
): Promise<{ ok: true; path: string; signedUrl: string } | { ok: false; error: string }> {
  const { core } = await getOrgContext(orgId);
  if (!isUuid(input.campaignId) || !(input.size > 0)) return { ok: false, error: 'invalid:file' };
  const { data: c } = await core.from('campaigns').select('org_id').eq('id', input.campaignId).maybeSingle();
  if (c?.org_id !== orgId) return { ok: false, error: 'not_found:campaign' };
  const bucket = input.kind === 'cover' ? 'campaign-covers' : 'campaign-assets';
  const folder = `${orgId}/${input.campaignId}/${input.kind === 'internal' ? 'internal/' : ''}`;
  const path = `${folder}${randomUUID().slice(0, 8)}-${safeName(input.filename)}`;
  const { data, error } = await core.storage.from(bucket).createSignedUploadUrl(path);
  if (error || !data) return { ok: false, error: error?.message || 'generic' };
  return { ok: true, path: data.path, signedUrl: data.signedUrl };
}
