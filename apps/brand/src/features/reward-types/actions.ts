'use server';

import { randomBytes } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { getOrgContext, isUuid } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

export interface RewardTypeInput {
  id?: string;
  name: string;
  code: string;
  kind: string;
  unit_label: string;
  idr_value_per_unit: number;
  decimals: number;
  fulfillment: 'manual_export' | 'code_pool' | 'webhook';
  recipient_schema: { key: string; label: string; pii: boolean; required: boolean }[];
  /** Tidak dikirim = stok tidak diubah. */
  stock?: number | null;
  /** Edit: stok yang dilihat saat form dibuka; berbeda dengan DB → stock_stale. */
  stock_expected?: number | null;
  webhook_url?: string;
  /** Webhook: buat secret HMAC baru (wajib saat pertama memilih webhook). */
  rotate_secret?: boolean;
}

/** F-B03 api.save_reward_type. Secret webhook dibuat di server, dikirim ke Vault lewat fungsi, dan hanya tampil sekali. */
export async function saveRewardType(orgId: string, input: RewardTypeInput): Promise<Result<{ id: string; secret?: string }>> {
  const { core } = await getOrgContext(orgId);
  const secret = input.fulfillment === 'webhook' && (!input.id || input.rotate_secret) ? randomBytes(32).toString('base64url') : undefined;
  const p: Record<string, unknown> = {
    ...(input.id ? { id: input.id } : { owner_org_id: orgId }),
    name: input.name.trim(),
    code: input.code.trim().toUpperCase(),
    kind: input.kind,
    unit_label: input.unit_label.trim(),
    idr_value_per_unit: input.idr_value_per_unit,
    decimals: input.decimals,
    fulfillment: input.fulfillment,
    recipient_schema: input.recipient_schema,
    ...(input.stock !== undefined ? { stock: input.stock } : {}),
    ...(input.stock_expected !== undefined ? { stock_expected: input.stock_expected } : {}),
  };
  if (input.fulfillment === 'webhook' && input.webhook_url?.trim()) p.webhook_url = input.webhook_url.trim();
  if (input.fulfillment !== 'webhook' && input.id) p.webhook_url = '';
  if (secret) p.webhook_secret = secret;
  const { data, error } = await core.rpc('save_reward_type', { p: p as never });
  if (error || !data) return fail(error);
  revalidatePath(`/${orgId}/reward-types`);
  return { ok: true, id: data, secret };
}

/** Pool kode voucher: maks 10.000 kode per unggahan, duplikat diabaikan DB. */
export async function uploadRewardCodes(orgId: string, rewardTypeId: string, codes: string[]): Promise<Result<{ added: number }>> {
  const { core } = await getOrgContext(orgId);
  if (!isUuid(rewardTypeId)) return { ok: false, error: 'not_found:reward_type' };
  const list = [...new Set(codes.map((c) => c.trim()).filter(Boolean))];
  if (!list.length || list.length > 10_000) return { ok: false, error: 'invalid:codes' };
  const { data, error } = await core.rpc('upload_reward_codes', { p_reward_type: rewardTypeId, p_codes: list });
  if (error) return fail(error);
  revalidatePath(`/${orgId}/reward-types`);
  return { ok: true, added: data ?? 0 };
}
