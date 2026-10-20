'use server';

import { revalidatePath } from 'next/cache';
import { getOrgContext } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

export type ControlAction =
  | { action: 'pause' | 'resume' | 'end_early' | 'notify_eligible' }
  | { action: 'extend'; submit_deadline: string }
  | { action: 'raise_rate'; rule_id: string; params: Record<string, unknown> }
  | { action: 'topup'; pools: { pool_id: string; amount: number }[] };

/** F-B06 api.control_campaign. */
export async function controlCampaign(orgId: string, campaignId: string, input: ControlAction): Promise<Result> {
  const { core } = await getOrgContext(orgId);
  const { action, ...params } = input;
  const { error } = await core.rpc('control_campaign', { p_campaign: campaignId, p_action: action, p_params: params as never });
  if (error) return fail(error);
  revalidatePath(`/${orgId}/campaigns/${campaignId}`);
  if (action === 'topup') revalidatePath(`/${orgId}/billing`);
  return { ok: true };
}

/** REV-4 pin berbayar → invoice pinned. */
export async function buyPin(orgId: string, campaignId: string, days: number): Promise<Result<{ invoiceId: string }>> {
  const { core } = await getOrgContext(orgId);
  const { data, error } = await core.rpc('buy_pin', { p_campaign: campaignId, p_days: Math.trunc(days) });
  if (error || !data) return fail(error);
  revalidatePath(`/${orgId}/billing`);
  return { ok: true, invoiceId: data };
}
