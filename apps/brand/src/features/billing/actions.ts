'use server';

import { revalidatePath } from 'next/cache';
import { requireBrandAal2 } from '@clipper/auth/server';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';
import type { RefundDest } from './refund-dest';

/** B3.7 sisa budget: rollover (kredit org) / refund (dikurangi biaya transfer). Uang brand bergerak → wajib aal2. */
export async function requestRefund(
  orgId: string,
  campaignId: string,
  mode: 'rollover' | 'refund',
  amount: number,
  idempotency: string,
  dest?: RefundDest,
): Promise<Result<{ id: string }>> {
  await requireBrandAal2();
  const { core } = await getOrgContext(orgId);
  if (!isUuid(campaignId) || !['rollover', 'refund'].includes(mode)) return { ok: false, error: 'invalid:mode' };
  const { data, error } = await core.rpc('request_refund', {
    p_org: orgId,
    p_campaign: campaignId,
    p_mode: mode,
    p_amount: Math.trunc(amount),
    p_idempotency: idempotency,
  });
  if (error || !data) return fail(error);
  revalidatePath(`/${orgId}/billing`);
  if (mode === 'refund' && dest) {
    // refund sudah tercatat; kalau rekening gagal disimpan, brand mengisinya dari tabel refund (Isi rekening)
    const r = await core.rpc('set_refund_dest', { p_refund: data, p_dest: dest });
    if (r.error) return fail(r.error);
  }
  return { ok: true, id: data };
}

/** AB-6 rekening tujuan refund (status requested; diganti sebelum disetujui finance). */
export async function setRefundDest(orgId: string, refundId: string, dest: RefundDest): Promise<Result> {
  await requireBrandAal2();
  const { core } = await getOrgContext(orgId);
  if (!isUuid(refundId)) return { ok: false, error: 'not_found:refund' };
  const { error } = await core.rpc('set_refund_dest', { p_refund: refundId, p_dest: dest });
  if (error) return fail(error);
  revalidatePath(`/${orgId}/billing`);
  return { ok: true };
}

/**
 * Pakai kredit org di invoice issued (api.pay_invoice_with_credit): amount null = semampunya, angka = persis, 0 = lepas cadangan.
 * Kredit menutup total → invoice lunas (channel credit); kalau tidak, sisa tagihan dibayar transfer/QRIS.
 */
export async function applyInvoiceCredit(
  orgId: string,
  invoiceId: string,
  amount: number | null,
): Promise<Result<{ creditApplied: number; due: number; paid: boolean }>> {
  await requireBrandAal2();
  const { core } = await getOrgContext(orgId);
  if (!isUuid(invoiceId)) return { ok: false, error: 'not_found:invoice' };
  if (amount != null && !(amount >= 0)) return { ok: false, error: 'invalid:amount' };
  const { data, error } = await core.rpc('pay_invoice_with_credit', {
    p_invoice: invoiceId,
    ...(amount == null ? {} : { p_amount: Math.round(amount * 100) / 100 }),
  });
  if (error) return fail(error);
  const r = (data ?? {}) as { credit_applied?: number; due?: number; paid?: boolean };
  revalidatePath(`/${orgId}`, 'layout');
  return { ok: true, creditApplied: Number(r.credit_applied ?? 0), due: Number(r.due ?? 0), paid: r.paid === true };
}
