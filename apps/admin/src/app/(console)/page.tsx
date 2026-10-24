import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import {
  Alert, Badge, Button, Card, CardHeader, CardTitle, EmptyState, formatIDR, formatNumber, Icon, PageHeader, RelativeTime, StatCard,
  type UiLocale,
} from '@clipper/ui';
import { must, param, rows, type SearchParams } from '@/lib/data';
import { resolveAlert } from '@/features/overview/actions';
import { ActionButton } from '@/features/shared/action-dialog';
import { JsonView } from '@/features/shared/json-view';
import { navFor } from '@/features/shell/nav';

interface Overview {
  gmv: { month: number; all_time: number };
  revenue: { month: number; all_time: number };
  active_campaigns: number;
  payout_pending: { count: number; sum: number };
  fraud_queue: number;
  tracking: { overdue: number; last_snapshot_age_seconds: number | null };
  open_alerts: number;
}

const ALERT_LINK: Record<string, string> = { payout: '/finance', reconcile: '/finance', fraud: '/fraud', fulfillment: '/fulfillment' };
const SEVERITY = { critical: 'danger', warning: 'warn', info: 'primary' } as const;

// F-A01 + A3.5: angka dari api.admin_overview (admin apa pun, aal2) + alert terbuka ops.alerts.
export default async function OverviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { claims } = await requireAdmin();
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const [ovRes, alertRes] = await Promise.all([
    db.rpc('admin_overview'),
    db.from('alerts').select('id, kind, severity, payload, created_at').is('resolved_at', null).order('created_at', { ascending: false }).limit(50),
  ]);
  const ov = must(ovRes) as unknown as Overview;
  const alerts = rows(alertRes);
  const money = (v: number) => formatIDR(Number(v), { locale: loc, compact: true });
  const age = ov.tracking.last_snapshot_age_seconds;
  const queues = navFor(claims.app_roles).filter((n) => n.key !== 'overview');

  return (
    <>
      <PageHeader title={t('overview.title')} description={t('overview.description')} />
      {param(sp, 'forbidden') ? (
        <Alert tone="warn" className="mb-5">
          {t('overview.forbidden')}
        </Alert>
      ) : null}

      <section aria-label={t('overview.statsLabel')} className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard variant="dark" label={t('overview.gmv')} value={money(ov.gmv.month)} icon="payments" hint={t('overview.allTime', { value: money(ov.gmv.all_time) })} />
        <StatCard label={t('overview.revenue')} value={money(ov.revenue.month)} icon="trending_up" hint={t('overview.allTime', { value: money(ov.revenue.all_time) })} />
        <StatCard label={t('overview.activeCampaigns')} value={formatNumber(ov.active_campaigns, loc)} icon="campaign" />
        <StatCard
          label={t('overview.payoutPending')}
          value={money(ov.payout_pending.sum)}
          icon="account_balance_wallet"
          hint={t('overview.payoutCount', { count: ov.payout_pending.count })}
        />
        <StatCard label={t('overview.fraudQueue')} value={formatNumber(ov.fraud_queue, loc)} icon="gavel" variant={ov.fraud_queue > 0 ? 'tint' : 'default'} />
        <StatCard
          label={t('overview.trackingOverdue')}
          value={formatNumber(ov.tracking.overdue, loc)}
          icon="monitoring"
          variant={ov.tracking.overdue > 0 ? 'tint' : 'default'}
          hint={age == null ? t('overview.noSnapshot') : t('overview.lastSnapshot', { minutes: Math.round(age / 60) })}
        />
        <StatCard label={t('overview.openAlerts')} value={formatNumber(ov.open_alerts, loc)} icon="notifications" />
      </section>

      <div className="mt-6 grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <Card padding="none">
          <CardHeader className="px-5 pt-5">
            <CardTitle>{t('overview.alerts')}</CardTitle>
          </CardHeader>
          {alerts.length === 0 ? (
            <EmptyState compact icon="check_circle" tone="success" title={t('overview.noAlerts')} className="pb-8" />
          ) : (
            <ul className="divide-y divide-border">
              {alerts.map((a) => {
                const group = a.kind?.split('.')[0] ?? '';
                return (
                  <li key={a.id} className="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-start">
                    <div className="flex min-w-0 flex-1 flex-col gap-1.5">
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge tone={SEVERITY[(a.severity ?? 'warning') as keyof typeof SEVERITY] ?? 'warn'} dot>
                          {t(`overview.severity.${a.severity ?? 'warning'}`)}
                        </Badge>
                        <span className="font-semibold text-ink">{t.has(`overview.alertKinds.${a.kind}`) ? t(`overview.alertKinds.${a.kind}`) : a.kind}</span>
                        <RelativeTime value={a.created_at!} locale={loc} className="text-caption text-muted" />
                      </div>
                      <JsonView value={a.payload} max={5} />
                    </div>
                    <div className="flex shrink-0 gap-2">
                      {ALERT_LINK[group] ? (
                        <Button href={ALERT_LINK[group]} linkAs={Link} size="sm" variant="tertiary" iconRight="arrow_forward">
                          {t('overview.followUp')}
                        </Button>
                      ) : null}
                      <ActionButton label={t('overview.resolve')} icon="check" success={t('overview.resolved')} action={resolveAlert.bind(null, a.id!)} direct />
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </Card>

        <Card padding="none">
          <CardHeader className="px-5 pt-5">
            <CardTitle>{t('overview.queues')}</CardTitle>
          </CardHeader>
          <ul className="flex flex-col p-2">
            {queues.map((q) => (
              <li key={q.key}>
                <Link href={q.href} className="flex h-12 items-center gap-3 rounded-[10px] px-3 text-sm font-semibold text-text-2 hover:bg-subtle hover:text-ink focus-ring">
                  <Icon name={q.icon} size={20} className="text-muted" />
                  <span className="flex-1">{t(`nav.${q.key}`)}</span>
                  <Icon name="chevron_right" size={18} className="text-faint" />
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </>
  );
}
