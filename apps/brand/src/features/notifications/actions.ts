'use server';

import { revalidatePath } from 'next/cache';
import { coreServer, requireBrand } from '@clipper/auth/server';
import { BRAND_EVENTS } from './events';

/** Tandai dibaca: satu notifikasi, atau semua notifikasi brand yang belum dibaca. */
export async function markNotificationsRead(id?: number): Promise<void> {
  const { claims } = await requireBrand();
  const core = await coreServer();
  let q = core.from('notifications').update({ read_at: new Date().toISOString() }).eq('user_id', claims.sub).is('read_at', null);
  q = id ? q.eq('id', id) : q.in('event', [...BRAND_EVENTS]);
  await q;
  revalidatePath('/', 'layout');
}
