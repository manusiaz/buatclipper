import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import { Button, EmptyState, Icon, RelativeTime, cn, type IconName } from '@clipper/ui';
import { markAllRead, openNotification } from '@/features/notifications/actions';
import { notificationViews } from '@/features/notifications/view';
import { core, uiLocale } from '@/features/lib/server';

export const metadata: Metadata = { title: 'Notifikasi' };

const ICON: Record<string, IconName> = {
  campaign: 'campaign',
  claim: 'timer',
  submission: 'checklist',
  social: 'link',
  earning: 'payments',
  payout: 'account_balance_wallet',
  fulfillment: 'redeem',
  kyc: 'id_card',
  broadcast: 'notifications',
  account: 'shield',
  invoice: 'receipt_long',
  budget: 'monitoring',
  org: 'storefront',
  agency: 'groups',
  refund: 'undo',
  managed: 'edit',
};

// F-C11: notifikasi in-app (E-23) 100 terbaru; buka = tandai dibaca + deep link per event.
export default async function NotificationsPage() {
  const { claims } = await requireClipper();
  const db = await core();
  const [t, locale, rows] = await Promise.all([
    getTranslations('clipper.notifications'),
    uiLocale(),
    db.from('notifications').select('id,event,payload,read_at,created_at').eq('user_id', claims.sub).order('created_at', { ascending: false }).limit(100),
  ]);
  const items = await notificationViews(rows.data ?? [], locale);
  const unread = items.filter((n) => !n.read).length;

  if (!items.length) {
    return (
      <EmptyState
        icon="notifications"
        tone="neutral"
        title={t('emptyTitle')}
        body={t('emptyBody')}
        action={{ label: t('toCampaigns'), href: '/campaigns', linkAs: Link }}
      />
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <p className="text-body-s text-muted">{unread ? t('unread', { n: unread }) : t('allRead')}</p>
        {unread ? (
          <form action={markAllRead}>
            <Button type="submit" size="sm" variant="ghost" iconLeft="check">
              {t('markAll')}
            </Button>
          </form>
        ) : null}
      </div>
      <ul className="surface-card flex flex-col divide-y divide-border overflow-hidden rounded-card">
        {items.map((n) => (
          <li key={n.id}>
            <form action={openNotification.bind(null, n.id, n.href)}>
              <button
                type="submit"
                className={cn(
                  'flex w-full items-start gap-3 px-4 py-3.5 text-left transition-colors hover:bg-subtle focus-ring',
                  !n.read && 'bg-primary-tint',
                )}
              >
                <span className={cn('grid size-10 shrink-0 place-items-center rounded-full', n.read ? 'bg-subtle text-muted' : 'bg-primary-soft text-primary-soft-fg')}>
                  <Icon name={ICON[n.event.split('.')[0] ?? ''] ?? 'notifications'} size={20} />
                </span>
                <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                  <span className={cn('text-body-s text-ink [overflow-wrap:anywhere]', !n.read && 'font-bold')}>{n.title}</span>
                  {n.body ? <span className="line-clamp-3 text-caption whitespace-pre-line text-text-2 [overflow-wrap:anywhere]">{n.body}</span> : null}
                  {n.reason ? <span className="line-clamp-2 text-caption text-muted [overflow-wrap:anywhere]">{n.reason}</span> : null}
                  <span className="text-caption text-muted">
                    <RelativeTime value={n.createdAt} locale={locale} />
                  </span>
                </span>
                {!n.read ? <span aria-label={t('new')} className="mt-1.5 size-2.5 shrink-0 rounded-full bg-primary" /> : null}
                {n.href ? <Icon name="chevron_right" size={20} className="mt-2 shrink-0 text-muted" /> : null}
              </button>
            </form>
          </li>
        ))}
      </ul>
    </div>
  );
}
