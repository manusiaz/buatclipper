import { getLocale, getTranslations } from 'next-intl/server';
import { formatIDR } from '@clipper/ui';
import { coreServer } from '@clipper/auth/server';
import { BRAND_EVENTS, isBrandEvent, notificationHref, notificationValues } from './events';
import { BellMenu, type BellItem } from './bell-menu';

export async function NotificationBell({ userId }: { userId: string }) {
  const [t, locale, core] = await Promise.all([getTranslations('brand'), getLocale(), coreServer()]);
  const events = [...BRAND_EVENTS];
  const [{ data }, { count }] = await Promise.all([
    core.from('notifications').select('id, event, payload, read_at, created_at').eq('user_id', userId).in('event', events)
      .order('created_at', { ascending: false }).limit(15),
    core.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', userId).in('event', events).is('read_at', null),
  ]);
  const loc = locale === 'en' ? 'en' : 'id';
  const items: BellItem[] = (data ?? []).flatMap((n) => {
    if (!isBrandEvent(n.event) || n.id == null) return [];
    const payload = (n.payload && typeof n.payload === 'object' && !Array.isArray(n.payload) ? n.payload : {}) as Record<string, unknown>;
    return [{
      id: n.id,
      text: t(`notif.${n.event}`, notificationValues(payload, (v) => formatIDR(v, { locale: loc }))),
      href: notificationHref(n.event, payload),
      createdAt: n.created_at ?? '',
      unread: !n.read_at,
    }];
  });
  return <BellMenu items={items} unread={count ?? 0} />;
}
