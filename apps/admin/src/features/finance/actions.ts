'use server';

import { revalidatePath } from 'next/cache';
import { coreServer, invokeFunction, requireAdmin } from '@clipper/auth/server';
import { settle, settleFn, text, type ActionResult } from '@/lib/action';
import { numeric } from '@/lib/data';
import { wibToIso } from '@/lib/wib';
import type { ExportResult } from '@/features/shared/export-panel';
import { MAX_BANK_LINES, parseBankCsv } from './bank';

const MAX_PROOF = 10 * 1024 * 1024; // bucket payout-proofs (pii-export MAX_PROOF_BYTES)
const PROOF_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];

async function finance() {
  await requireAdmin('admin_finance');
  return coreServer('admin');
}

/** A3.1: nominal = total invoice (amount_mismatch kalau beda), referensi unik (duplicate_payment_ref). */
export async function confirmInvoice(invoiceId: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const amount = text(fd, 'amount').replace(/[^\d.]/g, '');
  const { error } = await db.rpc('confirm_invoice_payment', {
    p_invoice: invoiceId,
    p_amount: numeric(amount),
    p_paid_at: wibToIso(text(fd, 'paid_at')) ?? new Date().toISOString(),
    p_ref: text(fd, 'ref'),
    p_channel: text(fd, 'channel'),
  });
  return settle(error, '/finance', '/campaigns');
}

/** A3.2: batch dari payout requested (channel batch) sampai cut-off. */
export async function createBatch(fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { data, error } = await db.rpc('create_payout_batch', { p_cutoff: wibToIso(text(fd, 'cutoff')) ?? new Date().toISOString() });
  if (!error && data === null) return { ...settle(null, '/finance'), ok: false, error: 'batch_all_held' }; // semua ditahan checkpoint
  return settle(error, '/finance');
}

/** Dua orang: approved_by ≠ created_by (constraint payout_batches_two_person → two_person). */
export async function approveBatch(batchId: string): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('approve_payout_batch', { p_batch: batchId });
  return settle(error, '/finance');
}

/**
 * A3.3: CSV transfer dibuat identity pii-export (satu-satunya tempat nomor rekening didekripsi). Batch yang sudah exported
 * hanya ditandatangani ulang (tanpa dekripsi, rows 0) → jumlah baris diambil dari batch (`rowsHint`).
 */
export async function exportPayoutCsv(batchId: string, rowsHint: number): Promise<ActionResult<ExportResult>> {
  await requireAdmin('admin_finance');
  const r = await invokeFunction<{ url: string; expires_in: number; rows: number; held: { payout_id: string; reason: string }[] }>(
    'identity', 'pii-export', { action: 'payout_csv', batch_id: batchId }, 'admin',
  );
  if (!r.ok) return { ok: false, error: r.error };
  revalidatePath('/finance');
  return { ok: true, data: { url: r.data.url, expires_in: r.data.expires_in, rows: r.data.rows || rowsHint, items: r.data.held.map((h) => ({ id: h.payout_id, reason: h.reason })) } };
}

/** A3.4: hasil transfer per payout (hanya yang masuk CSV = processing). failed → saldo kembali ke clipper (S-05). */
export async function markBatch(batchId: string, results: { payout_id: string; status: 'paid' | 'failed'; bank_ref: string; reason?: string }[]): Promise<ActionResult> {
  const db = await finance();
  if (results.some((r) => r.status === 'paid' && !r.bank_ref.trim())) return { ok: false, error: 'invalid:bank_ref' }; // rekonsiliasi per referensi
  const { error } = await db.rpc('mark_batch_paid', {
    p_batch: batchId,
    p_results: results.map((r) => ({
      payout_id: r.payout_id,
      status: r.status,
      bank_ref: r.bank_ref.trim() || null,
      ...(r.status === 'failed' && r.reason?.trim() ? { reason: r.reason.trim().slice(0, 500) } : {}),
    })),
  });
  return settle(error, '/finance');
}

/** B1.8: PDF faktur pajak (Coretax DJP) ke invoice-docs/{org}/{invoice}/…, lalu nomor + path dicatat api.attach_faktur. */
export async function attachFaktur(invoiceId: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const file = fd.get('file');
  if (!(file instanceof File) || file.size === 0) return { ok: false, error: 'invalid:file' };
  if (file.size > 5 * 1024 * 1024) return { ok: false, error: 'payload_too_large' };
  if (file.type !== 'application/pdf') return { ok: false, error: 'unsupported_type' };
  const no = text(fd, 'faktur_no');
  if (!/^[0-9][0-9.-]{11,24}$/.test(no)) return { ok: false, error: 'invalid:faktur_no' }; // sama dengan api.attach_faktur
  const { data: inv } = await db.from('invoices').select('org_id, faktur_path').eq('id', invoiceId).maybeSingle();
  if (!inv?.org_id) return { ok: false, error: 'not_found:invoice' };
  const path = `${inv.org_id}/${invoiceId}/${crypto.randomUUID()}.pdf`;
  const up = await db.storage.from('invoice-docs').upload(path, file, { contentType: 'application/pdf' });
  if (up.error) return { ok: false, error: 'upload_failed' };
  const { error } = await db.rpc('attach_faktur', { p_invoice: invoiceId, p_faktur_no: no, p_path: path });
  // berkas yang tidak (lagi) dirujuk invoice dihapus: unggahan yang ditolak, atau faktur lama yang diganti
  const stale = error ? path : inv.faktur_path && inv.faktur_path !== path ? inv.faktur_path : null;
  if (stale) await db.storage.from('invoice-docs').remove([stale]);
  return settle(error, '/finance');
}

/** Bukti transfer → pii-export upload_proof (batch: menutup batch yang sudah paid; refund: menandai refund dibayar). */
export async function uploadProof(target: 'batch' | 'refund', id: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_finance');
  const file = fd.get('file');
  if (!(file instanceof File) || file.size === 0) return { ok: false, error: 'invalid:file' };
  if (file.size > MAX_PROOF) return { ok: false, error: 'payload_too_large' };
  if (!PROOF_TYPES.includes(file.type)) return { ok: false, error: 'unsupported_type' };
  if (target === 'refund') {
    // Referensi mutasi dulu (finance.pay_refund mewajibkannya, dipakai rekonsiliasi bank); aman diulang.
    const { error } = await (await finance()).rpc('set_bank_ref', { p_target: 'refund', p_id: id, p_ref: text(fd, 'bank_ref') });
    if (error) return settle(error);
  }
  const content = Buffer.from(await file.arrayBuffer()).toString('base64');
  const r = await invokeFunction('identity', 'pii-export', {
    action: 'upload_proof', target, id, filename: file.name.slice(0, 200), content_type: file.type, content_base64: content,
  }, 'admin');
  return settleFn(r, '/finance');
}

/** Batalkan payout on_hold / batch requested: dana + fee kembali ke Tersedia. */
export async function cancelPayout(payoutId: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('cancel_payout', { p_payout: payoutId, p_reason: text(fd, 'reason') });
  return settle(error, '/finance');
}

export type RefundDestination = { bank_code: string; account_no: string; account_name: string; amount: string };

/** AB-6: rekening pribadi pemilik org perorangan (identity pii-export, diaudit) untuk transfer refund yang sudah disetujui. */
export async function revealRefundDest(refundId: string): Promise<ActionResult<RefundDestination>> {
  await requireAdmin('admin_finance');
  const r = await invokeFunction<RefundDestination>('identity', 'pii-export', { action: 'refund_destination', refund_id: refundId }, 'admin');
  return r.ok ? { ok: true, data: r.data } : { ok: false, error: r.error };
}

/** A3.6: refund disetujui admin_finance lain (constraint org_refunds_two_person). */
export async function approveRefund(refundId: string): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('approve_refund', { p_refund: refundId });
  return settle(error, '/finance');
}

/** Rekap PPh 21 (bruto per orang + NIK + nama KTP) dari pii-export; pajak tidak dihitung sistem. */
export async function exportPph21(fd: FormData): Promise<ActionResult<ExportResult>> {
  await requireAdmin('admin_finance');
  const r = await invokeFunction<{ url: string; expires_in: number; rows: number; missing_kyc: string[] }>(
    'identity', 'pii-export', { action: 'pph21', from: text(fd, 'from'), to: text(fd, 'to') }, 'admin',
  );
  if (!r.ok) return { ok: false, error: r.error };
  return { ok: true, data: { url: r.data.url, expires_in: r.data.expires_in, rows: r.data.rows, items: r.data.missing_kyc.map((id) => ({ id, reason: 'missing_kyc' })) } };
}

/** A3.5: CSV mutasi internet banking → api.import_bank_lines (cocok per referensi; selisih → alert reconcile.bank). */
export async function importBankStatement(fd: FormData): Promise<ActionResult<{ inserted: number; existing: number }>> {
  const db = await finance();
  const file = fd.get('file');
  const { lines, badRows } = file instanceof File && file.size > 0 ? parseBankCsv(await file.text()) : { lines: [], badRows: [1] };
  if (badRows.length || !lines.length) return { ok: false, error: `bank_csv:${(badRows.length ? badRows : [1]).slice(0, 10).join(',')}` };
  if (lines.length > MAX_BANK_LINES) return { ok: false, error: 'too_many_lines' };
  const { data, error } = await db.rpc('import_bank_lines', { p_lines: lines.map((l) => ({ ...l })) });
  if (error) return settle(error);
  settle(null, '/finance', '/');
  const r = (data ?? {}) as { inserted?: number; existing?: number };
  return { ok: true, data: { inserted: Number(r.inserted ?? 0), existing: Number(r.existing ?? 0) } };
}

/** Baris bank yang bukan transaksi sistem (biaya bank, bunga, setoran QRIS gabungan) ditutup dengan catatan. */
export async function resolveBankLine(id: number, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('resolve_bank_line', { p_id: id, p_note: text(fd, 'note') });
  return settle(error, '/finance');
}

/** A3.5: referensi mutasi payout batch / invoice yang salah ketik dikoreksi (catatan wajib, audit) lalu dicocokkan ulang. */
export async function setBankRef(target: 'payout' | 'invoice' | 'refund', id: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('set_bank_ref', { p_target: target, p_id: id, p_ref: text(fd, 'ref'), p_note: text(fd, 'note') });
  return settle(error, '/finance');
}

/** A3.2: tahan payout mencurigakan tanpa mengembalikan dana; lepas tahan setelah review (S-05 on_hold → requested). */
export async function holdPayout(payoutId: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('hold_payout', { p_payout: payoutId, p_reason: text(fd, 'reason') });
  return settle(error, '/finance');
}

export async function releasePayout(payoutId: string, fd: FormData): Promise<ActionResult> {
  const db = await finance();
  const { error } = await db.rpc('release_payout', { p_payout: payoutId, p_note: text(fd, 'note') });
  return settle(error, '/finance');
}
