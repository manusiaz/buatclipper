'use server';

import { revalidatePath } from 'next/cache';
import { requireBrandAal2 } from '@clipper/auth/server';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

/** B3.7 sisa budget: rollover (kredit org) / refund (dikurangi biaya transfer). Uang brand bergerak → wajib aal2. */
export async function requestRefund(
  orgId: string,
  campaignId: string,
  mode: 'rollover' | 'refund',
  amount: number,
  idempotency: string,
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
  return { ok: true, id: data };
}

/** Bayar invoice penuh dari kredit org (jurnal sama dengan transfer, channel credit). Replay = no-op di DB. */
export async function payInvoiceWithCredit(orgId: string, invoiceId: string): Promise<Result> {
  await requireBrandAal2();
  const { core } = await getOrgContext(orgId);
  if (!isUuid(invoiceId)) return { ok: false, error: 'not_found:invoice' };
  const { error } = await core.rpc('pay_invoice_with_credit', { p_invoice: invoiceId });
  if (error) return fail(error);
  revalidatePath(`/${orgId}`, 'layout');
  return { ok: true };
}
