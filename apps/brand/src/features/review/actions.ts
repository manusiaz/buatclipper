'use server';

import { revalidatePath } from 'next/cache';
import { getOrgContext, isUuid } from '@/lib/org';
import { REJECT_REASONS, type RejectReason } from './reasons';

/** F-B07 approve/reject massal → api.record_review per submisi (DB: review_mode brand, status in_review, owner/manager). */
export async function reviewSubmissions(
  orgId: string,
  ids: string[],
  decision: 'approve' | 'reject',
  reason?: RejectReason,
  message?: string,
): Promise<{ done: string[]; failed: { id: string; error: string }[] }> {
  const { core } = await getOrgContext(orgId);
  const list = [...new Set(ids)].filter(isUuid).slice(0, 100);
  const done: string[] = [];
  const failed: { id: string; error: string }[] = [];
  if (decision === 'reject' && !(reason && REJECT_REASONS.includes(reason))) return { done, failed: list.map((id) => ({ id, error: 'invalid:reason' })) };
  for (const id of list) {
    const { error } = await core.rpc('record_review', {
      p_target_type: 'submission',
      p_target_id: id,
      p_decision: decision,
      p_reason: decision === 'reject' ? reason : undefined,
      p_message: message?.trim().slice(0, 1000) || undefined,
    });
    if (error) failed.push({ id, error: error.message });
    else done.push(id);
  }
  revalidatePath(`/${orgId}`, 'layout');
  return { done, failed };
}
