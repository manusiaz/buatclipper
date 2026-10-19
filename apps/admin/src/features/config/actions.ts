'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';
import { isUuid } from '@/lib/data';
import type { Json } from './value';

const FEE_KEYS = ['mgmt_fee_pct', 'admin_fee_pct', 'clipper_fee_pct', 'instant_withdraw_fee'] as const;

/** F-A09 / A6.3: kunci E-25 (admin_super, tipe JSON sama) atau fee_rules.global; audit log sebelum/sesudah di update_config. */
export async function updateConfig(key: string, value: Json): Promise<ActionResult> {
  await requireAdmin('admin_super');
  if (key.startsWith('auth.')) return { ok: false, error: 'config_key_locked' };
  const db = await coreServer('admin');
  const { error } = await db.rpc('update_config', { p_key: key, p_value: value as never });
  return settle(error, '/config');
}

/** Override fee org (fee_rules.org) / campaign (fee_rules.campaign); clear = kembali ke aturan di atasnya. */
export async function updateFeeOverride(fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_super');
  const scope = text(fd, 'scope') === 'campaign' ? 'campaign' : 'org';
  const id = text(fd, 'target_id');
  if (!isUuid(id)) return { ok: false, error: 'invalid:target_id' };
  const value: Record<string, unknown> = { [scope === 'org' ? 'org_id' : 'campaign_id']: id };
  if (fd.get('clear') != null) value.clear = true;
  else for (const k of FEE_KEYS) if (text(fd, k)) value[k] = Number(text(fd, k));
  const db = await coreServer('admin');
  const { error } = await db.rpc('update_config', { p_key: `fee_rules.${scope}`, p_value: value as never });
  return settle(error, '/config');
}
