'use server';

import { coreServer, invokeFunction, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';
import type { ExportResult } from '@/features/shared/export-panel';

/** A5.1: CSV penerima reward manual_export dari identity pii-export; tanpa consent share_with_brand → dilewati (E-28). */
export async function exportRecipients(rewardTypeId: string): Promise<ActionResult<ExportResult>> {
  await requireAdmin('admin_ops', 'admin_finance');
  const r = await invokeFunction<{ url: string; expires_in: number; rows: number; skipped: { fulfillment_id: string; reason: string }[] }>(
    'identity', 'pii-export', { action: 'recipients_csv', reward_type_id: rewardTypeId }, 'admin',
  );
  if (!r.ok) return { ok: false, error: r.error };
  return { ok: true, data: { url: r.data.url, expires_in: r.data.expires_in, rows: r.data.rows, items: r.data.skipped.map((s) => ({ id: s.fulfillment_id, reason: s.reason })) } };
}

/** S-06 batal/kembalikan klaim (kode voucher yang sudah terpasang tidak bisa → code_assigned). */
export async function cancelFulfillment(id: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops', 'admin_finance');
  const db = await coreServer('admin');
  const { error } = await db.rpc('cancel_fulfillment', { p_fulfillment: id, p_reason: text(fd, 'reason') });
  return settle(error, '/fulfillment');
}
