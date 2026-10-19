'use server';

import { revalidatePath } from 'next/cache';
import { hosts } from '@clipper/auth';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

/** F-B09 link laporan read-only 90 hari; token hanya dikembalikan sekali. */
export async function createReportLink(orgId: string, campaignId: string): Promise<Result<{ url: string }>> {
  const { core } = await getOrgContext(orgId);
  const { data, error } = await core.rpc('create_report_link', { p_campaign: campaignId, p_days: 90 });
  if (error || !data) return fail(error?.code === '42501' ? { message: 'auth:forbidden' } : error);
  revalidatePath(`/${orgId}/campaigns/${campaignId}`);
  return { ok: true, url: `${hosts.web}/r/${data}` };
}

export async function revokeReportLink(orgId: string, campaignId: string, linkId: string): Promise<Result> {
  const { core } = await getOrgContext(orgId);
  if (!isUuid(linkId)) return { ok: false, error: 'not_found:generic' };
  const { error } = await core.rpc('revoke_report_link', { p_link: linkId });
  if (error) return fail(error.code === '42501' ? { message: 'auth:forbidden' } : error);
  revalidatePath(`/${orgId}/campaigns/${campaignId}`);
  return { ok: true };
}
