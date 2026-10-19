'use server';

import { revalidatePath } from 'next/cache';
import { getOrgContext } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

/** F-B11 api.invite_to_campaign (maks 500 username per panggilan). */
export async function inviteClippers(orgId: string, campaignId: string, raw: string): Promise<Result<{ added: number; sent: number }>> {
  const { core } = await getOrgContext(orgId);
  const usernames = [...new Set(raw.split(/[\s,;]+/).map((u) => u.replace(/^@/, '').trim().toLowerCase()).filter(Boolean))];
  if (!usernames.length) return { ok: false, error: 'invalid:usernames' };
  if (usernames.length > 500) return { ok: false, error: 'invalid:usernames_max' };
  const { data, error } = await core.rpc('invite_to_campaign', { p_campaign: campaignId, p_usernames: usernames });
  if (error) return fail(error);
  revalidatePath(`/${orgId}/campaigns/${campaignId}`);
  return { ok: true, added: data ?? 0, sent: usernames.length };
}
