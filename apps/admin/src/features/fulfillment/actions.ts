'use server';

import { coreServer, invokeFunction, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';
import type { ExportResult } from '@/features/shared/export-panel';
import { MAX_CODES, parseCodes } from './codes';

/** A5.1: CSV penerima reward manual_export dari identity pii-export; tanpa consent share_with_brand → dilewati (E-28). */
export async function exportRecipients(rewardTypeId: string): Promise<ActionResult<ExportResult>> {
  await requireAdmin('admin_ops', 'admin_finance');
  const r = await invokeFunction<{ url: string; expires_in: number; rows: number; skipped: { fulfillment_id: string; reason: string }[] }>(
    'identity', 'pii-export', { action: 'recipients_csv', reward_type_id: rewardTypeId }, 'admin',
  );
  if (!r.ok) return { ok: false, error: r.error };
  return { ok: true, data: { url: r.data.url, expires_in: r.data.expires_in, rows: r.data.rows, items: r.data.skipped.map((s) => ({ id: s.fulfillment_id, reason: s.reason })) } };
}

/** A5.1 link baru untuk CSV penerima yang sudah diserahkan (link 15 menit kedaluwarsa); tidak mengekspor klaim baru. */
export async function resignRecipients(rewardTypeId: string, fileRef: string, rows: number): Promise<ActionResult<ExportResult>> {
  await requireAdmin('admin_ops', 'admin_finance');
  const r = await invokeFunction<{ url: string; expires_in: number }>(
    'identity', 'pii-export', { action: 'recipients_resign', reward_type_id: rewardTypeId, file_ref: fileRef }, 'admin',
  );
  if (!r.ok) return { ok: false, error: r.error };
  return { ok: true, data: { url: r.data.url, expires_in: r.data.expires_in, rows, items: [] } };
}

/** S-06 batal/kembalikan klaim (kode voucher yang sudah terpasang tidak bisa → code_assigned). */
export async function cancelFulfillment(id: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops', 'admin_finance');
  const db = await coreServer('admin');
  const { error } = await db.rpc('cancel_fulfillment', {
    p_fulfillment: id,
    p_reason: text(fd, 'reason'),
    p_confirmed_not_delivered: fd.get('not_delivered') === 'on',
  });
  return settle(error, '/fulfillment');
}

/** A5.1 tandai terkirim (manual_export, atau webhook macet yang dikonfirmasi brand) + referensi kiriman. admin_ops. */
export async function markDelivered(id: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { error } = await db.rpc('mark_fulfillment_delivered', { p_fulfillment: id, p_ref: text(fd, 'ref') });
  return settle(error, '/fulfillment');
}

/** J-A5 webhook macet (12× gagal): kirim ulang setelah brand memperbaiki endpoint. admin_ops. */
export async function retryFulfillment(id: string): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { error } = await db.rpc('retry_fulfillment', { p_fulfillment: id });
  return settle(error, '/fulfillment');
}

/** Pool kode voucher (code_pool): teks dan/atau berkas .txt/.csv, satu kode per baris/koma; ≤ 10.000 per unggahan. */
export async function uploadCodes(rewardTypeId: string, fd: FormData): Promise<ActionResult<{ count: number }>> {
  await requireAdmin('admin_ops');
  const file = fd.get('file');
  const raw = `${text(fd, 'codes')}\n${file instanceof File && file.size > 0 ? await file.text() : ''}`;
  const codes = parseCodes(raw);
  if (codes.length === 0) return { ok: false, error: 'invalid:codes' };
  if (codes.length > MAX_CODES) return { ok: false, error: 'too_many_codes' };
  const db = await coreServer('admin');
  const { data, error } = await db.rpc('upload_reward_codes', { p_reward_type: rewardTypeId, p_codes: codes });
  if (error) return settle(error);
  settle(null, '/fulfillment');
  return { ok: true, data: { count: data ?? 0 } };
}
