'use server';

import { randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { persistCampaign, untilReplicated, type SaveResult } from '@clipper/campaign-builder';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

/** F-B10 duplikat / simpan sebagai template (hasil selalu draft): isi di brand, lalu pool & rule di admin setelah salinan tiba. */
export async function duplicateCampaign(orgId: string, campaignId: string, asTemplate: boolean): Promise<Result<{ id: string }>> {
  const { core, brand } = await getOrgContext(orgId);
  const { data, error } = await brand.rpc('duplicate_campaign', { p_campaign: campaignId, p_as_template: asTemplate });
  if (error || !data) return fail(error);
  const copied = await untilReplicated(() => core.rpc('copy_campaign_economics', { p_from: campaignId, p_to: data }));
  if (copied.error) return fail(copied.error);
  revalidatePath(`/${orgId}/campaigns`);
  return { ok: true, id: data };
}

/**
 * Builder: isi + aset ke api.save_campaign brand, jadwal/pool/rule/pengajuan ke api.save_campaign admin (persistCampaign).
 * Sengaja tanpa revalidatePath: revalidasi di action merender ulang halaman builder yang sedang diedit (autosave); halaman lain
 * dinamis dan dimuat segar saat dibuka.
 */
export async function saveCampaign(orgId: string, payload: Record<string, unknown>, submit: boolean): Promise<SaveResult> {
  const { core, brand } = await getOrgContext(orgId);
  const body = payload.id ? payload : { ...payload, org_id: orgId };
  return persistCampaign({ brand, core }, body, submit);
}

const safeName = (name: string) =>
  name.toLowerCase().normalize('NFKD').replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(-80) || 'file';

/**
 * Signed upload URL (storage brand, policy campaign_files_write): cover → campaign-covers/{org}/{campaign}/…,
 * aset → campaign-assets/{org}/{campaign}/…, brief mentah → campaign-assets/{org}/{campaign}/internal/…
 */
export async function campaignUploadUrl(
  orgId: string,
  input: { campaignId: string; kind: 'cover' | 'asset' | 'internal'; filename: string; contentType: string; size: number },
): Promise<{ ok: true; path: string; signedUrl: string } | { ok: false; error: string }> {
  const { brand } = await getOrgContext(orgId);
  if (!isUuid(input.campaignId) || !(input.size > 0)) return { ok: false, error: 'invalid:file' };
  const { data: c } = await brand.from('campaigns').select('org_id').eq('id', input.campaignId).maybeSingle();
  if (c?.org_id !== orgId) return { ok: false, error: 'not_found:campaign' };
  const bucket = input.kind === 'cover' ? 'campaign-covers' : 'campaign-assets';
  const folder = `${orgId}/${input.campaignId}/${input.kind === 'internal' ? 'internal/' : ''}`;
  const path = `${folder}${randomUUID().slice(0, 8)}-${safeName(input.filename)}`;
  const { data, error } = await brand.storage.from(bucket).createSignedUploadUrl(path);
  if (error || !data) return { ok: false, error: error?.message || 'generic' };
  return { ok: true, path: data.path, signedUrl: data.signedUrl };
}
