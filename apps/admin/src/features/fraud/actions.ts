'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';

export type FraudAction = 'hold' | 'reverse' | 'suspend' | 'ban' | 'dismiss';

/**
 * F-A06 / A4.2: hold | reverse | suspend (30 hari) | ban (core memanggil bridge identity ban_user sendiri) | dismiss.
 * admin_moderator aal2; tercatat audit log + riwayat Trust Score.
 */
export async function resolveFlag(flagId: string, action: FraudAction, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const db = await coreServer('admin');
  const { error } = await db.rpc('resolve_fraud_flag', { p_flag: flagId, p_action: action, p_note: text(fd, 'note') });
  return settle(error, '/fraud', '/');
}
