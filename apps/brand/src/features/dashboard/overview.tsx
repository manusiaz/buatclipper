import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Alert,
  Badge,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  EmbedFrame,
  EmptyState,
  ProgressBar,
  StatCard,
  Table,
  TBody,
  TD,
  TH,
  THead,
  TR,
  formatCompact,
  formatDate,
  formatDateTime,
  formatIDR,
  formatNumber,
  platformLabel,
  type Platform,
} from '@clipper/ui';
import { DailyChart, PlatformChart } from './charts';
import { lowProjection, type CampaignStats } from './stats';

const units = (v: number, code: string, unit: string, loc: 'id' | 'en', decimals = 0) =>
  code === 'IDR' ? formatIDR(v, { locale: loc }) : `${formatNumber(v, loc, { maximumFractionDigits: Math.max(decimals, 2) })} ${unit}`;

export async function Overview({
  stats,
  status,
  alerts,
  inviteTab,
  base,
}: {
  stats: CampaignStats;
  status: string;
  alerts: { kind: string; created_at: string }[];
  inviteTab: boolean;
  base: string;
}) {
  const [t, locale] = await Promise.all([getTranslations('brand.dashboard'), getLocale()]);
  const loc = locale === 'en' ? 'en' : 'id';
  const p = stats.projection;
  const platforms = Object.entries(stats.byPlatform)
    .sort((a, b) => b[1] - a[1])
    .map(([platform, views]) => ({ platform: platformLabel(platform as Platform), views }));
  const suggestions = [
    { key: 'raise_rate', tab: 'controls' },
    { key: 'extend', tab: 'controls' },
    ...(inviteTab ? [{ key: 'invite', tab: 'invites' }] : []),
    { key: 'pin', tab: 'pin' },
  ];

  return (
    <div className="flex flex-col gap-5">
      {lowProjection(stats, status) ? (
        <Alert tone="warn" title={t('lowTitle', { pct: formatNumber(p.projectedUtilizationPct ?? 0, loc, { maximumFractionDigits: 1 }) })}>
          <p>{t('lowBody')}</p>
          <ul className="mt-2 flex flex-wrap gap-2">
            {suggestions.map((s) => (
              <li key={s.key}>
                <Link href={`${base}?tab=${s.tab}`} className="inline-flex min-h-9 items-center rounded-full bg-surface px-3 text-body-s font-semibold text-link shadow-card focus-ring">
                  {t(`suggest.${s.key}`)}
                </Link>
              </li>
            ))}
          </ul>
        </Alert>
      ) : null}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4 [&>*]:min-w-0">
        <StatCard variant="dark" icon="visibility" label={t('viewsValid')} value={formatCompact(stats.viewsValid, loc)} hint={formatNumber(stats.viewsValid, loc)} />
        <StatCard
          icon="payments"
          label={t('spent')}
          value={formatIDR(stats.spentIdr, { locale: loc, compact: stats.spentIdr >= 10_000_000 })}
          hint={t('ofBudget', { budget: formatIDR(stats.budgetIdr, { locale: loc }) })}
        />
        <StatCard
          icon="insights"
          label={t('ecpm')}
          value={stats.ecpmIdr == null ? '—' : formatIDR(stats.ecpmIdr, { locale: loc })}
          hint={t('ecpmHint')}
        />
        <StatCard icon="groups" label={t('clips')} value={formatNumber(stats.clips, loc)} hint={t('clippers', { count: stats.clippers })} />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('utilization')}</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <ProgressBar
            value={Math.min(100, stats.utilizationPct ?? 0)}
            label={t('utilizationLabel')}
            showLabel
            valueLabel={`${formatNumber(stats.utilizationPct ?? 0, loc, { maximumFractionDigits: 1 })}%`}
            tone="auto"
            size="lg"
          />
          <dl className="grid grid-cols-1 gap-3 text-body-s sm:grid-cols-3 [&>*]:min-w-0">
            <div>
              <dt className="text-muted">{t('remaining')}</dt>
              <dd className="font-semibold text-ink tnum">{formatIDR(stats.remainingIdr, { locale: loc })}</dd>
            </div>
            <div>
              <dt className="text-muted">{t('projected')}</dt>
              <dd className="font-semibold text-ink tnum">
                {p.projectedUtilizationPct == null ? '—' : `${formatNumber(p.projectedUtilizationPct, loc, { maximumFractionDigits: 1 })}%`}
                {p.horizonAt ? <span className="block text-caption font-normal text-muted">{t('until', { date: formatDate(p.horizonAt, loc) })}</span> : null}
              </dd>
            </div>
            <div>
              <dt className="text-muted">{t('exhaustAt')}</dt>
              <dd className="font-semibold text-ink">
                {p.projectedExhaustAt ? formatDateTime(p.projectedExhaustAt, loc) : t('notExhausting')}
                {p.exhaustsBeforeHorizon ? <Badge size="sm" tone="danger" className="ml-2">{t('beforeHorizon')}</Badge> : null}
              </dd>
            </div>
          </dl>
          {alerts.length ? (
            <ul className="flex flex-wrap gap-2" aria-label={t('alertsLabel')}>
              {alerts.map((a) => (
                <li key={a.kind}>
                  <Badge tone={a.kind === 'projection_low' ? 'warn' : a.kind === 'used_100' ? 'danger' : 'primary'} icon="notifications">
                    {t(`alert.${a.kind}`)} · {formatDate(a.created_at, loc)}
                  </Badge>
                </li>
              ))}
            </ul>
          ) : null}
        </CardContent>
      </Card>

      {stats.pools.length ? (
        <Table caption={t('pools')} captionVisible>
          <THead>
            <TR>
              <TH>{t('poolType')}</TH>
              <TH align="right">{t('poolTotal')}</TH>
              <TH align="right">{t('poolUsed')}</TH>
              <TH align="right">{t('poolRemaining')}</TH>
              <TH align="right">{t('poolCap')}</TH>
              <TH>{t('poolViews')}</TH>
            </TR>
          </THead>
          <TBody>
            {stats.pools.map((pl) => (
              <TR key={pl.poolId}>
                <TD><Badge tone="outline">{pl.code}</Badge></TD>
                <TD numeric>{units(pl.total, pl.code, pl.unitLabel, loc, pl.decimals)}</TD>
                <TD numeric>{units(pl.allocated, pl.code, pl.unitLabel, loc, pl.decimals)}</TD>
                <TD numeric className="font-semibold">{units(pl.remaining, pl.code, pl.unitLabel, loc, pl.decimals)}</TD>
                <TD numeric muted>{pl.maxPerClip == null ? '—' : units(pl.maxPerClip, pl.code, pl.unitLabel, loc, pl.decimals)}</TD>
                <TD muted className="min-w-[240px] whitespace-normal">
                  {Object.entries(pl.estRemainingViews).length
                    ? Object.entries(pl.estRemainingViews).map(([pf, v]) => `${platformLabel(pf as Platform)} ${formatCompact(v, loc)}`).join(' · ')
                    : '—'}
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      ) : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2 [&>*]:min-w-0">
        <Card>
          <CardHeader><CardTitle>{t('byPlatform')}</CardTitle></CardHeader>
          <CardContent>
            {platforms.length ? (
              <PlatformChart data={platforms} caption={t('byPlatform')} labels={{ platform: t('platform'), views: t('views') }} />
            ) : (
              <EmptyState compact icon="bar_chart" title={t('noData')} />
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle>{t('daily')}</CardTitle></CardHeader>
          <CardContent>
            {stats.daily.length ? (
              <DailyChart data={stats.daily} caption={t('daily')} labels={{ day: t('day'), views: t('views') }} />
            ) : (
              <EmptyState compact icon="trending_up" title={t('noData')} />
            )}
          </CardContent>
        </Card>
      </div>

      <section aria-labelledby="top-clips" className="flex flex-col gap-3">
        <h2 id="top-clips" className="text-h5 text-ink">{t('topClips')}</h2>
        {stats.topClips.length ? (
          <ul className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3 [&>*]:min-w-0 max-sm:[&>li:nth-child(n+4)]:hidden">
            {stats.topClips.slice(0, 6).map((c, i) => (
              <li key={c.url}>
                <Card padding="sm" className="flex flex-col items-center gap-2">
                  <p className="flex w-full items-center justify-between gap-2 text-body-s">
                    <span className="font-bold text-muted tnum">#{i + 1}</span>
                    <span className="font-bold text-ink tnum">{t('viewsCount', { views: formatNumber(c.views, loc) })}</span>
                  </p>
                  <EmbedFrame url={c.url} title={t('clipTitle', { rank: i + 1 })} openLabel={t('openClip')} maxWidth={300} />
                </Card>
              </li>
            ))}
          </ul>
        ) : (
          <Card padding="lg"><EmptyState compact icon="movie" title={t('noClips')} body={t('noClipsBody')} /></Card>
        )}
      </section>
    </div>
  );
}
