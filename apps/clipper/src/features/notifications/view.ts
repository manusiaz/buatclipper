// Baris api.notifications → judul/isi terjemahan (namespace notifications) + link (builder murni di render.ts).
import { getTranslations } from 'next-intl/server';
import { hosts } from '@clipper/auth';
import type { UiLocale } from '@clipper/ui';
import { buildNotificationViews, type NotificationRow, type NotificationView } from '@clipper/clipper-lib/notifications';

export type { NotificationRow, NotificationView };

export async function notificationViews(rows: NotificationRow[], locale: UiLocale): Promise<NotificationView[]> {
  const [t, tc] = await Promise.all([getTranslations('notifications'), getTranslations('common')]);
  return buildNotificationViews(
    rows,
    locale,
    (k, v) => t(k as Parameters<typeof t>[0], v),
    (k) => tc(k as Parameters<typeof tc>[0]),
    { brand: hosts.brand, accounts: hosts.accounts },
  );
}
