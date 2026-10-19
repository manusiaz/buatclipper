import type { ReactNode } from 'react';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Container,
  EmbedFrame,
  EmptyState,
  PlatformChip,
  PlatformIcon,
  ProgressBar,
  StatCard,
  StatusBadge,
  TBody,
  TD,
  TH,
  THead,
  TR,
  Table,
  formatCompact,
  formatIDR,
  formatNumber,
  platformLabels,
  type UiLocale,
} from '@clipper/ui';
import { formatWib } from '../campaign-public/format';
import type { Report } from './parse';
import { PrintButton } from './print-button';

function Panel({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section aria-labelledby={id} className="surface-card flex break-inside-avoid flex-col gap-4 rounded-card p-5 md:p-6 print:border print:border-border print:shadow-none">
      <h2 id={id} className="text-h5 text-ink">
        {title}
      </h2>
      {children}
    </section>
  );
}

/** F-B09 laporan read-only: angka agregat campaign_report, tanpa data pribadi clipper; cetak = PDF. */
export async function ReportView({ report: r }: { report: Report }) {
  const [t, ts, locale] = await Promise.all([getTranslations('web.report'), getTranslations('web.status'), getLocale() as Promise<UiLocale>]);
  const n = (v: number) => formatNumber(v, locale);
  const amount = (v: number, b: Report['budget'][number]) =>
    b.code === 'IDR' ? formatIDR(v, { locale }) : `${formatNumber(v, locale, { maximumFractionDigits: b.decimals })} ${b.unit || b.code}`;
  const totalViews = r.byPlatform.reduce((a, b) => a + b.views, 0);
  const idrSpent = r.budget.find((b) => b.code === 'IDR')?.spent ?? 0;
  const c = r.campaign;
  const period = [c.startAt, c.submitDeadline].map((d) => (d ? formatWib(d, locale) : t('tbd'))).join(' – ');

  return (
    <Container size="md" className="flex flex-col gap-6 py-8 md:py-12 print:max-w-none print:px-0 print:py-0">
      <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div className="flex min-w-0 flex-col gap-2">
          <p className="text-overline text-primary-soft-fg uppercase">{t('eyebrow')}</p>
          <h1 className="text-h2 break-words text-ink">{c.title}</h1>
          <div className="flex flex-wrap items-center gap-2">
            {c.status ? <StatusBadge kind="campaign" status={c.status} label={ts.has(c.status) ? ts(c.status) : c.status} /> : null}
            {c.platforms.map((p) => (
              <PlatformChip key={p} platform={p} />
            ))}
          </div>
          <p className="text-body-s text-muted">
            {t('period')}: {period}
          </p>
        </div>
        <PrintButton label={t('print')} />
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatCard label={t('views')} value={n(r.viewsValid)} icon="visibility" className="col-span-2 md:col-span-1" />
        <StatCard label={t('clips')} value={n(r.clips)} icon="movie" />
        <StatCard label={t('clippers')} value={n(r.clippers)} icon="groups" />
        <StatCard
          label={t('ecpm')}
          value={r.viewsValid > 0 && idrSpent > 0 ? formatIDR(Math.round((idrSpent / r.viewsValid) * 1000), { locale }) : '—'}
          icon="trending_up"
          hint={t('ecpmHint')}
          className="col-span-2 md:col-span-1"
        />
      </div>

      {r.clips === 0 ? (
        <EmptyState icon="monitoring" title={t('emptyTitle')} body={t('emptyBody')} className="surface-card rounded-card" />
      ) : (
        <>
          <div className="grid gap-4 md:grid-cols-2">
            <Panel id="by-platform" title={t('platformTitle')}>
              {r.byPlatform.length ? (
                <ul className="flex flex-col gap-4">
                  {r.byPlatform.map((p) => {
                    const pct = totalViews > 0 ? (p.views / totalViews) * 100 : 0;
                    return (
                      <li key={p.platform} className="flex flex-col gap-1.5">
                        <div className="flex items-center justify-between gap-3 text-body-s">
                          <span className="inline-flex items-center gap-1.5 font-semibold text-ink">
                            <PlatformIcon platform={p.platform} size={16} />
                            {platformLabels[p.platform]}
                          </span>
                          <span className="text-text-2 tnum">
                            {formatCompact(p.views, locale)} · {formatNumber(pct, locale, { maximumFractionDigits: 1 })}%
                          </span>
                        </div>
                        <ProgressBar value={pct} label={platformLabels[p.platform]} size="sm" />
                      </li>
                    );
                  })}
                </ul>
              ) : (
                <p className="text-body-s text-muted">{t('noPlatform')}</p>
              )}
            </Panel>

            <Panel id="budget" title={t('budgetTitle')}>
              {r.budget.length ? (
                <ul className="flex flex-col gap-4">
                  {r.budget.map((b) => (
                    <li key={b.code} className="flex flex-col gap-1.5">
                      <ProgressBar
                        value={b.total > 0 ? Math.min(100, (b.spent / b.total) * 100) : 0}
                        label={b.code === 'IDR' ? 'Rupiah' : b.unit || b.code}
                        showLabel
                        tone="auto"
                      />
                      <p className="text-caption text-muted tnum">{t('spent', { spent: amount(b.spent, b), total: amount(b.total, b) })}</p>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="text-body-s text-muted">{t('noBudget')}</p>
              )}
            </Panel>
          </div>

          {r.topClips.length ? (
            <section aria-labelledby="top-clips" className="flex flex-col gap-4">
              <h2 id="top-clips" className="text-h5 text-ink">
                {t('topTitle')}
              </h2>
              <Table caption={t('topTitle')}>
                <THead>
                  <TR>
                    <TH className="w-12">{t('rank')}</TH>
                    <TH>{t('platform')}</TH>
                    <TH>{t('link')}</TH>
                    <TH align="right">{t('viewsCol')}</TH>
                  </TR>
                </THead>
                <TBody>
                  {r.topClips.map((clip, i) => (
                    <TR key={clip.url}>
                      <TD muted className="tnum">
                        {i + 1}
                      </TD>
                      <TD>
                        {clip.platform ? (
                          <span className="inline-flex items-center gap-1.5">
                            <PlatformIcon platform={clip.platform} size={16} />
                            {platformLabels[clip.platform]}
                          </span>
                        ) : (
                          '—'
                        )}
                      </TD>
                      <TD className="max-w-[18rem]">
                        <a
                          href={clip.url}
                          target="_blank"
                          rel="noopener noreferrer nofollow"
                          className="block truncate rounded-tag font-semibold text-link hover:underline focus-ring print:whitespace-normal print:break-all"
                        >
                          {clip.url.replace(/^https:\/\/(www\.)?/, '')}
                        </a>
                      </TD>
                      <TD numeric className="tnum">
                        {n(clip.views)}
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </Table>
              <div className="flex flex-col gap-3 print:hidden">
                <h3 className="text-h6 text-ink">{t('watchTop')}</h3>
                <div className="grid justify-items-center gap-4 sm:grid-cols-2 lg:grid-cols-3">
                  {r.topClips.slice(0, 3).map((clip, i) => (
                    <EmbedFrame key={clip.url} url={clip.url} title={t('embedTitle', { rank: i + 1 })} openLabel={t('openClip')} />
                  ))}
                </div>
              </div>
            </section>
          ) : null}
        </>
      )}

      <p className="text-caption text-muted">
        {t('note')} {t('generated', { date: formatWib(new Date().toISOString(), locale) })}
      </p>
    </Container>
  );
}
