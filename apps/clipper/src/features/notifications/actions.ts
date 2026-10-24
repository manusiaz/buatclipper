'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { requireClipper } from '@clipper/auth/server';
import { hosts, safeNext } from '@clipper/auth';
import { core } from '../lib/server';

const refresh = () => {
  revalidatePath('/notifications');
  revalidatePath('/', 'layout'); // angka lonceng di header
};

/** Tandai dibaca (grant update read_at di api.notifications) lalu buka tujuan. */
export async function openNotification(id: number, href: string | null): Promise<void> {
  const { claims } = await requireClipper();
  if (Number.isSafeInteger(id)) {
    const db = await core();
    await db.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', id).eq('user_id', claims.sub).is('read_at', null);
  }
  refresh();
  if (href) redirect(href.startsWith('/') ? safeNext(href, '/notifications') : safeNext(href, `${hosts.app}/notifications`));
}

export async function markAllRead(): Promise<void> {
  const { claims } = await requireClipper();
  const db = await core();
  await db.from('notifications').update({ read_at: new Date().toISOString() }).eq('user_id', claims.sub).is('read_at', null);
  refresh();
}
