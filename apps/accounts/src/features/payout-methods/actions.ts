'use server';

import { revalidatePath } from 'next/cache';
import { safeNext } from '@clipper/auth';
import { invokeFunction } from '@clipper/auth/server';
import { refreshSession } from '@clipper/auth/actions';
import { dbCode } from '@/lib/errors';
import { identityDb } from '@/lib/identity';
import { withParams } from '@/lib/url';
import type { MethodKind } from './rules';

type Result = { ok: true; redirect?: string } | { ok: false; error: string };

/** C1.13: member-data mencocokkan nama pemilik dengan nama KYC, HMAC nomor (unik) + enkripsi. */
export async function addPayoutMethod(input: {
  kind: MethodKind;
  bankCode: string;
  accountNo: string;
  accountName: string;
  next?: string;
}): Promise<Result> {
  const r = await invokeFunction<{ id: string; last4: string }>('identity', 'member-data', {
    action: 'add_payout_method',
    kind: input.kind,
    bank_code: input.bankCode,
    account_no: input.accountNo,
    account_name: input.accountName,
  });
  if (!r.ok) return { ok: false, error: r.error };
  revalidatePath('/', 'layout');
  return { ok: true, redirect: input.next ? withParams(safeNext(input.next), { method_id: r.data.id }) : undefined };
}

/**
 * C6.1: alamat/HP reward fisik disimpan di identity (E-29) → recipient_ref untuk request_fulfillment di app. Data hanya
 * dibagikan ke brand dengan consent share_with_brand, jadi consent dicatat dulu bila user mencentangnya.
 */
export async function saveRecipient(input: {
  rewardTypeId: string;
  data: Record<string, string>;
  grantShare: boolean;
  next?: string;
}): Promise<Result> {
  if (input.grantShare) {
    const id = await identityDb();
    const { error } = await id.rpc('record_consent', { p_kind: 'share_with_brand' });
    if (error) return { ok: false, error: dbCode(error) };
    await refreshSession('sso'); // claim consent_ok.share_with_brand dibaca core saat klaim reward
  }
  const data = Object.fromEntries(Object.entries(input.data).map(([k, v]) => [k, v.trim()]).filter(([, v]) => v));
  const r = await invokeFunction<{ recipient_ref: string }>('identity', 'member-data', {
    action: 'save_recipient',
    reward_type_id: input.rewardTypeId,
    data,
  });
  if (!r.ok) return { ok: false, error: r.error };
  revalidatePath('/', 'layout');
  return { ok: true, redirect: input.next ? withParams(safeNext(input.next), { recipient_ref: r.data.recipient_ref }) : undefined };
}
