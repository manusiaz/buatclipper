'use server';

import { revalidatePath } from 'next/cache';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import type { ActionResult } from '@/lib/action';
import { dbError } from '@/lib/errors';
import { isUuid } from '@/lib/data';

export interface BulkResult {
  done: number;
  failed: { id: string; error: string }[];
}

/**
 * F-A05 massal: record_review per submisi (in_review: approve/reject; appealed: approve = overturn, reject = uphold —
 * trust.apply_submission_decision). Satu RPC per submisi supaya kegagalan satu baris tidak membatalkan yang lain.
 */
export async function decideSubmissions(
  ids: string[],
  decision: 'approve' | 'reject',
  input: { reason?: string; message?: string; note?: string },
): Promise<ActionResult<BulkResult>> {
  await requireAdmin('admin_moderator');
  const list = ids.filter(isUuid).slice(0, 100);
  if (decision === 'reject' && !input.reason) return { ok: false, error: 'invalid:reason' };
  const db = await coreServer('admin');
  const out: BulkResult = { done: 0, failed: [] };
  for (const id of list) {
    const { error } = await db.rpc('record_review', {
      p_target_type: 'submission',
      p_target_id: id,
      p_decision: decision,
      p_reason: input.reason || undefined,
      p_message: input.message?.trim() || undefined,
      p_note: input.note?.trim() || undefined,
    });
    if (error) out.failed.push({ id, error: dbError(error) });
    else out.done++;
  }
  revalidatePath('/review');
  return { ok: true, data: out };
}
