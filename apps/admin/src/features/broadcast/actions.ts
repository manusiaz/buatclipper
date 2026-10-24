'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';
import { wibToIso } from '@/lib/wib';
import { channelsFrom, segmentFrom } from './segment';

/** F-A12 / A6.1: E-42 terjadwal → job broadcast-dispatch → enqueue_notification per penerima (admin_ops aal2). */
export async function sendBroadcast(fd: FormData): Promise<ActionResult> {
  const security = fd.get('security') === 'on';
  await requireAdmin(security ? 'admin_super' : 'admin_ops');
  const get = (k: string) => (typeof fd.get(k) === 'string' ? (fd.get(k) as string) : null);
  const channels = security ? ['in_app', 'email'] : channelsFrom(get);
  if (!channels.length) return { ok: false, error: 'invalid:channels' };
  const db = await coreServer('admin');
  const { error } = await db.rpc('send_broadcast', {
    p_title: text(fd, 'title'),
    p_body: text(fd, 'body'),
    p_segment: security ? {} : segmentFrom(get),
    p_channels: channels,
    p_scheduled_at: wibToIso(text(fd, 'scheduled_at')) ?? undefined,
    p_kind: security ? 'security' : 'promo',
  });
  return settle(error, '/broadcast');
}
