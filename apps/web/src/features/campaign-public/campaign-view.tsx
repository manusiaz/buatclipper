import type { ReactNode } from 'react';
import Image from 'next/image';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Avatar,
  Badge,
  Button,
  Card,
  Container,
  Icon,
  PlatformChip,
  PlatformIcon,
  ProgressBar,
  StatusBadge,
  earningFor,
  formatCompact,
  formatIDR,
  formatNumber,
  platformLabels,
  toEmbedUrl,
  type UiLocale,
} from '@clipper/ui';
import { Markdown } from '@/components/markdown';
import { coverUrl } from '@/lib/cover';
import { idrRates, mergeViewRates, parseRule, rateGroups, type Rule } from '@/lib/rates';
import { clipperHref } from '@/lib/session';
import type { PublicCampaign } from './data';
import { formatAmount, formatWib } from './format';

type T = Awaited<ReturnType<typeof getTranslations<'web.campaign'>>>;

function Block({ title, children, id }: { title: string; children: ReactNode; id?: string }) {
  return (
    <section aria-labelledby={id} className="surface-card flex flex-col gap-3 rounded-card p-5 md:p-6">
      <h2 id={id} className="text-h5 text-ink">
        {title}
      </h2>
      {children}
    </section>
  );
}

function RuleLine({ rule, t, locale }: { rule: Rule; t: T; locale: UiLocale }) {
  const p = parseRule(rule.kind, rule.params);
  if (!p) return null;
  const amt = (v: number) => formatAmount(v, rule, locale);
  const views = (v: number) => formatNumber(v, locale);
  switch (p.kind) {
    case 'per_1k_views':
      return (
        <li className="flex items-baseline gap-1.5">
          <span className="text-h4 text-ink tnum">{amt(p.rate)}</span>
          <span className="text-body-s text-muted">{t('per1k')}</span>
        </li>
      );
    case 'flat_per_post':
      return <li className="text-body-s font-semibold text-ink">{t('flat', { amount: amt(p.amount) })}</li>;
    case 'milestone_bonus':
      return <li className="text-body-s font-semibold text-ink">{t('milestone', { amount: amt(p.amount), views: views(p.threshold) })}</li>;
    case 'tiered_cpm':
      return (
        <li className="flex flex-col gap-1 text-body-s">
          {p.tiers.map((tier) => (
            <span key={`${tier.from}-${tier.to}`} className="flex justify-between gap-3">
              <span className="text-muted">
                {tier.to != null ? t('tierRange', { from: views(tier.from), to: views(tier.to) }) : t('tierFrom', { from: views(tier.from) })}
              </span>
              <span className="font-semibold text-ink tnum">{t('tierRate', { amount: amt(tier.rate) })}</span>
            </span>
          ))}
        </li>
      );
  }
}

function closedReason(c: PublicCampaign['campaign'], t: T): string | null {
  if (c.status === 'paused') return t('closedPaused');
  if (c.status === 'exhausted') return t('closedExhausted');
  if (c.status !== 'live' || (c.submit_deadline && Date.parse(c.submit_deadline) <= Date.now())) return t('closedEnded');
  return null;
}

/** F-X02 halaman campaign publik: brief, rate per platform, budget, jadwal WIB, syarat, CTA claim lewat login. */
export async function CampaignView({ data, session, category }: { data: PublicCampaign; session: boolean; category?: string }) {
  const [t, ts, locale] = await Promise.all([
    getTranslations('web.campaign'),
    getTranslations('web.status'),
    getLocale() as Promise<UiLocale>,
  ]);
  const { campaign: c, rules, pools, faq, coverPath, brand, viewsLeft } = data;
  const platforms = c.platforms;
  const cover = coverUrl(coverPath);
  const groups = rateGroups(rules, platforms);
  const topIdr = Math.max(0, ...idrRates(rules, platforms).map((r) => r.ratePer1k));
  const closed = closedReason(c, t);
  const href = clipperHref(session, `/campaigns/${c.id}`);

  const hashtags = (c.required_hashtags ?? []).map((h) => (h.startsWith('#') ? h : `#${h}`));
  const mentions = (c.required_mentions ?? []).map((m) => (m.startsWith('@') ? m : `@${m}`));
  const links = c.required_links ?? [];
  const dos = c.dos ?? [];
  const donts = c.donts ?? [];
  const examples = (c.example_urls ?? []).filter((u) => u.startsWith('https://'));

  const req: string[] = [];
  if (c.min_followers) req.push(t('reqFollowers', { n: formatNumber(c.min_followers, locale) }));
  if (c.min_account_age_days) req.push(t('reqAccountAge', { n: c.min_account_age_days }));
  if (c.kyc_required) req.push(t('reqKyc'));
  if (c.min_views) req.push(t('reqMinViews', { n: formatNumber(c.min_views, locale) }));
  if (c.max_clips_per_clipper) req.push(t('reqMaxClips', { n: c.max_clips_per_clipper }));
  if (c.min_duration_sec && c.max_duration_sec) req.push(t('reqDuration', { min: c.min_duration_sec, max: c.max_duration_sec }));
  else if (c.min_duration_sec) req.push(t('reqDurationMin', { min: c.min_duration_sec }));
  else if (c.max_duration_sec) req.push(t('reqDurationMax', { max: c.max_duration_sec }));

  const cta = closed ? (
    <div className="flex flex-col gap-1.5" role="group" aria-label={closed}>
      <div aria-disabled="true" className="flex h-12 items-center justify-center gap-2 rounded-control border-[1.5px] border-border bg-disabled text-sm font-bold text-muted">
        <Icon name="lock" size={18} />
        {t('claimClosed')}
      </div>
      <p className="text-center text-caption text-muted">{closed}</p>
    </div>
  ) : (
    <div className="flex flex-col gap-1.5">
      <Button href={href} size="lg" fullWidth iconRight="arrow_forward">
        {session ? t('openApp') : t('claim')}
      </Button>
      {session ? null : <p className="text-center text-caption text-muted">{t('claimNote')}</p>}
    </div>
  );

  const timeline: Array<[string, string]> = [
    [t('start'), c.start_at ? formatWib(c.start_at, locale) : t('tbd')],
    [t('deadline'), c.submit_deadline ? formatWib(c.submit_deadline, locale) : t('tbd')],
    [t('window'), t('windowValue', { days: c.view_window_days ?? 30 })],
  ];

  return (
    <Container className="pt-4 pb-28 md:pt-8 lg:pb-16">
      <Link href="/#campaigns" className="mb-4 inline-flex min-h-11 items-center gap-1 rounded-tag text-body-s font-semibold text-link focus-ring">
        <Icon name="arrow_back" size={18} />
        {t('back')}
      </Link>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start">
        <header className="flex flex-col gap-5 lg:col-start-1">
          <div className="relative aspect-[16/9] overflow-hidden rounded-media bg-navy shadow-card">
            {cover ? (
              <Image src={cover} alt="" fill preload sizes="(min-width: 1024px) 760px, 100vw" className="object-cover" />
            ) : (
              <div className="surface-dark grid size-full place-items-center text-white/60">
                <Icon name="movie" size={56} />
              </div>
            )}
          </div>
          <div className="flex flex-col gap-3">
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge kind="campaign" status={c.status} label={ts(c.status)} />
              {category ? <Badge tone="outline">{category}</Badge> : null}
              {platforms.map((p) => (
                <PlatformChip key={p} platform={p} />
              ))}
            </div>
            <h1 className="text-h2 break-words text-ink">{c.title}</h1>
            {brand ? (
              <p className="flex min-w-0 items-center gap-2 text-body-s text-text-2">
                <Avatar name={brand.name} size={24} shape="square" />
                <span className="truncate font-semibold">{t('byBrand', { brand: brand.name })}</span>
                {brand.verified ? <Icon name="verified" size={16} filled className="shrink-0 text-primary" title={t('brandVerified')} /> : null}
              </p>
            ) : null}
          </div>
        </header>

        <aside className="flex flex-col gap-4 lg:sticky lg:top-20 lg:col-start-2 lg:row-span-2 lg:row-start-1">
          <Card variant="raised" padding="lg" className="flex flex-col gap-5">
            <section aria-labelledby="rate-title" className="flex flex-col gap-3">
              <h2 id="rate-title" className="text-overline text-muted uppercase">
                {t('rateTitle')}
              </h2>
              {groups.length ? (
                groups.map((g) => (
                  <div key={g.platforms.join()} className="flex flex-col gap-2">
                    <p className="flex flex-wrap items-center gap-1.5 text-caption font-semibold text-text-2">
                      {g.platforms.length === platforms.length && platforms.length > 1 ? (
                        t('allPlatforms')
                      ) : (
                        g.platforms.map((p) => (
                          <span key={p} className="inline-flex items-center gap-1">
                            <PlatformIcon platform={p} size={14} />
                            {platformLabels[p]}
                          </span>
                        ))
                      )}
                    </p>
                    <ul className="flex flex-col gap-1.5">
                      {mergeViewRates(g.rules).map((r, i) => (
                        <RuleLine key={i} rule={r} t={t} locale={locale} />
                      ))}
                    </ul>
                  </div>
                ))
              ) : (
                <p className="text-body-s text-muted">{t('noRates')}</p>
              )}
              {topIdr > 0 ? (
                <p className="flex items-center gap-1.5 rounded-chip bg-success-bg px-3 py-2 text-body-s font-semibold text-success-fg">
                  <Icon name="payments" size={16} filled />
                  <span className="tnum">
                    {t('example', { views: formatNumber(10_000, locale), amount: formatIDR(earningFor(10_000, topIdr), { locale }) })}
                  </span>
                </p>
              ) : null}
            </section>

            {pools.length ? (
              <section aria-labelledby="budget-title" className="flex flex-col gap-3">
                <h2 id="budget-title" className="text-overline text-muted uppercase">
                  {t('budgetTitle')}
                </h2>
                {pools.map((p) => (
                  <div key={p.id} className="flex flex-col gap-1.5">
                    <ProgressBar
                      value={p.total > 0 ? Math.min(100, (p.allocated / p.total) * 100) : 0}
                      label={pools.length > 1 ? `${t('budgetUsed')} · ${p.code === 'IDR' ? 'Rupiah' : (p.unit_label ?? p.code)}` : t('budgetUsed')}
                      showLabel
                      tone="auto"
                    />
                    <p className="text-caption text-muted tnum">
                      {t('remaining', { amount: formatAmount(p.remaining, p, locale), total: formatAmount(p.total, p, locale) })}
                    </p>
                  </div>
                ))}
                {viewsLeft != null ? <p className="text-body-s font-semibold text-text-2 tnum">{t('viewsLeft', { views: formatCompact(viewsLeft, locale) })}</p> : null}
              </section>
            ) : null}

            <section aria-labelledby="timeline-title" className="flex flex-col gap-2">
              <h2 id="timeline-title" className="text-overline text-muted uppercase">
                {t('timelineTitle')}
              </h2>
              <dl className="flex flex-col gap-2">
                {timeline.map(([k, v]) => (
                  <div key={k} className="flex flex-col">
                    <dt className="text-caption text-muted">{k}</dt>
                    <dd className="text-body-s font-semibold text-ink">{v}</dd>
                  </div>
                ))}
              </dl>
            </section>

            <div id="claim">{cta}</div>
          </Card>
        </aside>

        <div className="flex min-w-0 flex-col gap-4 lg:col-start-1">
          <Block title={t('briefTitle')} id="brief-title">
            {c.brief?.trim() ? <Markdown headingOffset={2}>{c.brief}</Markdown> : <p className="text-body-s text-muted">{t('noBrief')}</p>}
          </Block>

          {hashtags.length || mentions.length || links.length || c.sponsored_label ? (
            <Block title={t('mustTitle')} id="must-title">
              {[
                [t('hashtags'), hashtags],
                [t('mentions'), mentions],
                [t('links'), links],
              ].map(([label, list]) =>
                (list as string[]).length ? (
                  <div key={label as string} className="flex flex-col gap-1.5">
                    <p className="text-caption font-semibold text-muted">{label}</p>
                    <ul className="flex flex-wrap gap-1.5">
                      {(list as string[]).map((x) => (
                        <li key={x}>
                          <Badge tone="primary" className="max-w-full font-mono break-all">
                            {x}
                          </Badge>
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : null,
              )}
              {c.sponsored_label ? (
                <p className="flex items-start gap-2 text-body-s text-text-2">
                  <Icon name="info" size={18} className="mt-0.5 shrink-0 text-primary" />
                  {t('sponsored')}
                </p>
              ) : null}
            </Block>
          ) : null}

          <Block title={t('reqTitle')} id="req-title">
            {req.length ? (
              <ul className="flex flex-col gap-2">
                {req.map((r) => (
                  <li key={r} className="flex items-start gap-2 text-body-s text-text-2">
                    <Icon name="check_small" size={20} className="shrink-0 text-success" />
                    {r}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-body-s text-muted">{t('noReq')}</p>
            )}
          </Block>

          {dos.length || donts.length ? (
            <div className="grid gap-4 md:grid-cols-2">
              {[
                { title: t('dosTitle'), list: dos, icon: 'check_circle' as const, cls: 'text-success' },
                { title: t('dontsTitle'), list: donts, icon: 'cancel' as const, cls: 'text-danger' },
              ].map((b) =>
                b.list.length ? (
                  <Block key={b.title} title={b.title}>
                    <ul className="flex flex-col gap-2">
                      {b.list.map((x) => (
                        <li key={x} className="flex items-start gap-2 text-body-s break-words text-text-2">
                          <Icon name={b.icon} size={18} filled className={`mt-0.5 shrink-0 ${b.cls}`} />
                          {x}
                        </li>
                      ))}
                    </ul>
                  </Block>
                ) : null,
              )}
            </div>
          ) : null}

          {examples.length ? (
            <Block title={t('examplesTitle')} id="examples-title">
              <ul className="grid gap-2 sm:grid-cols-2">
                {examples.map((u) => {
                  const platform = toEmbedUrl(u)?.platform;
                  let host = u;
                  try {
                    host = new URL(u).hostname.replace(/^www\./, '');
                  } catch {
                    /* URL rusak tetap tampil apa adanya */
                  }
                  return (
                    <li key={u}>
                      <a
                        href={u}
                        target="_blank"
                        rel="noopener noreferrer nofollow"
                        className="flex min-h-12 items-center gap-3 rounded-card-sm border border-border bg-surface-2 px-3 py-2 text-body-s font-semibold text-ink hover:border-border-hover focus-ring"
                      >
                        {platform ? <PlatformIcon platform={platform} size={18} /> : <Icon name="link" size={18} className="text-muted" />}
                        <span className="min-w-0 flex-1 truncate">{platform ? platformLabels[platform] : host}</span>
                        <Icon name="open_in_new" size={16} className="text-muted" />
                        <span className="sr-only">{t('openExample')}</span>
                      </a>
                    </li>
                  );
                })}
              </ul>
            </Block>
          ) : null}

          {faq.length ? (
            <Block title={t('faqTitle')} id="faq-title">
              <div className="-mx-1 divide-y divide-border">
                {faq.map((f) => (
                  <details key={f.q} className="group">
                    <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between gap-3 rounded-control px-1 py-3 text-body font-semibold text-ink focus-ring [&::-webkit-details-marker]:hidden">
                      {f.q}
                      <Icon name="expand_more" size={20} className="shrink-0 text-muted transition-transform duration-220 group-open:rotate-180" />
                    </summary>
                    <p className="px-1 pb-3 text-body-s whitespace-pre-line text-text-2">{f.a}</p>
                  </details>
                ))}
              </div>
            </Block>
          ) : null}
        </div>
      </div>

      {closed ? null : (
        <div className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface/95 px-4 pt-3 pb-safe shadow-pop backdrop-blur-md lg:hidden print:hidden">
          <div className="mx-auto flex max-w-[680px] items-center gap-3 pb-3">
            {topIdr > 0 ? (
              <p className="min-w-0 flex-1 leading-tight">
                <span className="block text-h6 text-ink tnum">{formatIDR(topIdr, { locale })}</span>
                <span className="text-caption text-muted">{t('per1k')}</span>
              </p>
            ) : null}
            <Button href={href} iconRight="arrow_forward" className={topIdr > 0 ? 'shrink-0' : 'flex-1'}>
              {session ? t('openApp') : t('claim')}
            </Button>
          </div>
        </div>
      )}
    </Container>
  );
}
