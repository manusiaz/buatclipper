'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';

export type FraudAction = 'warn' | 'hold' | 'reverse' | 'suspend' | 'ban' | 'dismiss';

/**
 * F-A06 / A4.2: warn | hold | reverse | suspend (30 hari) | ban (core memanggil bridge identity ban_user sendiri) | dismiss.
 * admin_moderator aal2; tercatat audit log + riwayat Trust Score.
 */
export async function resolveFlag(flagId: string, action: FraudAction, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const db = await coreServer('admin');
  const { error } = await db.rpc('resolve_fraud_flag', { p_flag: flagId, p_action: action, p_note: text(fd, 'note') });
  return settle(error, '/fraud', '/');
}

/** §12 banding sanksi (sekali per sanksi): dikabulkan → efek dibalik sejauh aman, ditolak → final. admin_moderator. */
export async function decideSanctionAppeal(sanctionId: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const db = await coreServer('admin');
  const { error } = await db.rpc('decide_sanction_appeal', { p_sanction: sanctionId, p_decision: text(fd, 'decision'), p_note: text(fd, 'note') });
  return settle(error, '/fraud', '/users');
}

/** R30-1: clipper yang login-nya diblokir (ban / suspend login) membanding lewat bantuan; dicatat admin_support atas namanya. */
export async function recordSanctionAppeal(sanctionId: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_support', 'admin_moderator');
  const db = await coreServer('admin');
  const { error } = await db.rpc('record_sanction_appeal', { p_sanction: sanctionId, p_message: text(fd, 'message') });
  return settle(error, '/users', '/fraud');
}
