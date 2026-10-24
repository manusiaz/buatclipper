'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, type ActionResult } from '@/lib/action';

/** F-A01/F-X01: tutup alert (admin apa pun, aal2). */
export async function resolveAlert(id: number): Promise<ActionResult> {
  await requireAdmin();
  const db = await coreServer('admin');
  const { error } = await db.rpc('resolve_alert', { p_id: id });
  return settle(error, '/');
}
