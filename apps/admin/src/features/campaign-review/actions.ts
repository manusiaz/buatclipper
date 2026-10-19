'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { optText, settle, type ActionResult } from '@/lib/action';

/** F-A02: approve (invoice campaign harus lunas → invoice_unpaid) / reject + alasan standar. admin_ops aal2. */
export async function reviewCampaign(id: string, decision: 'approve' | 'reject', fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { error } = await db.rpc('record_review', {
    p_target_type: 'campaign',
    p_target_id: id,
    p_decision: decision,
    p_reason: optText(fd, 'reason') ?? undefined,
    p_message: optText(fd, 'message') ?? undefined,
    p_note: optText(fd, 'note') ?? undefined,
  });
  return settle(error, '/campaigns');
}
