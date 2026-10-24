'use server';

import { revalidatePath } from 'next/cache';
import { requireClipper } from '@clipper/auth/server';
import { isUuid } from '@clipper/clipper-lib/pure';
import { core, fail, ok, type Result } from '../lib/server';

/** F-C05: reservasi 1 slot (claim_campaign, kedaluwarsa 48 jam). Error = kode yang sama dengan cta_state. */
export async function claimCampaign(campaignId: string): Promise<Result<{ claimId: string; expiresAt: string }>> {
  await requireClipper();
  if (!isUuid(campaignId)) return fail('not_found:campaign');
  const db = await core();
  const { data, error } = await db.rpc('claim_campaign', { p_campaign: campaignId });
  if (error || !data) return fail(error?.message);
  revalidatePath(`/campaigns/${campaignId}`);
  revalidatePath('/campaigns');
  revalidatePath('/tasks');
  return ok({ claimId: data.id ?? '', expiresAt: data.expires_at ?? '' });
}
