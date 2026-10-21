'use server';

import { revalidatePath } from 'next/cache';
import { requireClipper } from '@clipper/auth/server';
import { isUuid } from '@clipper/clipper-lib/pure';
import { core, fail, ok, type Result } from '../lib/server';

const KEY = /^[A-Za-z0-9-]{8,100}$/;

/** F-C09/F-C15: tarik Rupiah (batch gratis / instant berbayar). idempotency dari client → klik ganda tidak memotong 2×. */
export async function requestPayout(input: {
  method: string;
  amount: number;
  channel: 'batch' | 'instant';
  idempotency: string;
}): Promise<Result<{ status: string }>> {
  await requireClipper();
  if (!isUuid(input.method)) return fail('invalid:method');
  if (!Number.isInteger(input.amount) || input.amount <= 0) return fail('invalid:amount');
  if (input.channel !== 'batch' && input.channel !== 'instant') return fail('invalid:channel');
  if (!KEY.test(input.idempotency ?? '')) return fail('invalid:idempotency');
  const db = await core();
  const { data, error } = await db.rpc('request_payout', {
    p_method: input.method,
    p_amount: input.amount,
    p_channel: input.channel,
    p_idempotency: input.idempotency,
  });
  if (error) return fail(error.message);
  revalidatePath('/wallet');
  revalidatePath('/wallet/withdraw');
  return ok({ status: data?.status ?? 'requested' });
}

/** F-C09 non-tunai: field non-PII inline; field PII hanya lewat recipient_ref (data penerima di identity, E-29). */
export async function requestFulfillment(input: {
  rewardType: string;
  amount: number;
  recipient: Record<string, string>;
  recipientRef: string | null;
  idempotency: string;
}): Promise<Result<{ status: string }>> {
  await requireClipper();
  if (!isUuid(input.rewardType)) return fail('invalid:reward_type');
  if (!Number.isFinite(input.amount) || input.amount <= 0) return fail('invalid:amount');
  if (input.recipientRef !== null && !isUuid(input.recipientRef)) return fail('recipient_ref_required');
  if (!KEY.test(input.idempotency ?? '')) return fail('invalid:idempotency');
  const recipient = Object.fromEntries(
    Object.entries(input.recipient ?? {})
      .filter(([k, v]) => /^[a-z0-9_]{1,40}$/i.test(k) && typeof v === 'string')
      .map(([k, v]) => [k, v.trim().slice(0, 200)]),
  );
  const db = await core();
  const { data, error } = await db.rpc('request_fulfillment', {
    p_reward_type: input.rewardType,
    p_amount: input.amount,
    p_recipient: recipient,
    p_recipient_ref: input.recipientRef as string,
    p_idempotency: input.idempotency,
  });
  if (error) return fail(error.message);
  revalidatePath('/wallet');
  revalidatePath('/wallet/withdraw');
  return ok({ status: data?.status ?? 'requested' });
}
