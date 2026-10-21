import { Suspense, type ReactNode } from 'react';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Badge,
  Button,
  CampaignCardSkeleton,
  Card,
  Container,
  Icon,
  Logo,
  PlatformChip,
  Section,
  StatCard,
  earningFor,
  formatIDR,
  formatNumber,
  platformLabels,
  type IconName,
  type UiLocale,
} from '@clipper/ui';
import { globalFeeOrDefault } from '@/lib/catalog';
import type { PublicSettings } from '@/lib/settings';
import { brandHref, clipperHref } from '@/lib/session';
import { HeroCampaign, topLiveRate } from './campaign-grid';
import { brandCost } from './fees';

const EXAMPLE_VIEWS = 10_000;
const EXAMPLE_RATE = 2_000;
// Nav bawah app clipper (§6.8) di mockup HP hero.
const MOCK_NAV = [
  ['campaigns', 'campaign'],
  ['tasks', 'checklist'],
  ['wallet', 'account_balance_wallet'],
  ['social', 'link'],
] as const satisfies ReadonlyArray<readonly [string, IconName]>;

async function ctx() {
  const [t, locale] = await Promise.all([getTranslations('web'), getLocale() as Promise<UiLocale>]);
  return { t, locale, idr: (v: number) => formatIDR(v, { locale }), n: (v: number) => formatNumber(v, locale) };
}

function StepCard({ n, icon, title, body }: { n: number; icon: IconName; title: string; body: ReactNode }) {
  return (
    <li className="surface-card flex flex-col gap-3 rounded-card p-5">
      <div className="flex items-center justify-between">
        <span className="grid size-11 place-items-center rounded-[30%] bg-primary-soft text-primary-soft-fg">
          <Icon name={icon} size={24} filled />
        </span>
        <span aria-hidden className="text-h4 text-faint tnum">
          {String(n).padStart(2, '0')}
        </span>
      </div>
      <h3 className="text-h6 text-ink">{title}</h3>
      <p className="text-body-s text-muted">{body}</p>
    </li>
  );
}

export async function Hero({ session, settings }: { session: boolean; settings: PublicSettings }) {
  const { t, idr, n } = await ctx();
  return (
    <section aria-labelledby="hero-title">
      <Container className="grid items-center gap-10 py-10 md:py-20 lg:grid-cols-[1.2fr_0.8fr] lg:gap-14">
        <div className="flex flex-col gap-5">
          <p className="text-overline text-primary-soft-fg uppercase">{t('hero.eyebrow')}</p>
          <h1 id="hero-title" className="text-h1 text-ink md:text-display">
            {t.rich('hero.title', { hl: (c) => <span className="text-primary">{c}</span> })}
          </h1>
          <p className="max-w-[52ch] text-body-l text-muted">{t('hero.body')}</p>
          <div className="flex flex-wrap gap-3">
            <Button href={clipperHref(session)} size="lg" iconRight="arrow_forward">
              {session ? t('nav.openApp') : t('nav.start')}
            </Button>
            <Button href="#brand" variant="secondary" size="lg">
              {t('nav.brand')}
            </Button>
          </div>
          <ul className="flex flex-col gap-2 pt-1 text-body-s text-text-2 sm:flex-row sm:flex-wrap sm:gap-x-6">
            {(['free', 'own', 'weekly'] as const).map((k) => (
              <li key={k} className="flex items-center gap-2">
                <Icon name="check_circle" size={18} filled className="shrink-0 text-success" />
                {t(`hero.points.${k}`)}
              </li>
            ))}
          </ul>
        </div>

        {/* DS 16 Hero Split + 18 Layered: layar app asli di mockup HP, kartu kaca melayang, blob dekor (hanya token). */}
        <div className="relative mx-auto w-full max-w-[400px] lg:max-w-[460px] lg:pb-14">
          <div aria-hidden className="pointer-events-none absolute -top-10 right-0 size-72 rounded-full bg-primary/25 blur-3xl" />
          <div aria-hidden className="pointer-events-none absolute bottom-0 -left-10 size-64 rounded-full bg-primary-soft-hover blur-3xl" />
          <figure aria-label={t('hero.mockLabel')} className="relative mx-auto w-[272px] rounded-[46px] bg-navy p-[9px] shadow-pop ring-1 ring-border-strong sm:w-[288px]">
            <div className="relative flex h-[500px] flex-col overflow-hidden rounded-[38px] bg-page text-ink sm:h-[540px]">
              <div aria-hidden className="flex h-9 shrink-0 items-center justify-between px-6 text-[11px] font-semibold tnum">
                <span>9:41</span>
                <span className="absolute top-2 left-1/2 h-6 w-24 -translate-x-1/2 rounded-full bg-navy" />
                <span className="flex gap-0.5">
                  {[0, 1, 2].map((i) => (
                    <span key={i} className="h-2 w-1 rounded-full bg-current" style={{ opacity: 0.4 + i * 0.3 }} />
                  ))}
                </span>
              </div>
              <div aria-hidden className="flex items-center justify-between px-4 pb-2">
                <Logo size={22} />
                <Icon name="notifications" size={20} className="text-muted" />
              </div>
              <p aria-hidden className="px-4 pb-2 text-h6">{t('hero.mockTitle')}</p>
              <div className="min-h-0 flex-1 px-3">
                <Suspense fallback={<CampaignCardSkeleton />}>
                  <HeroCampaign session={session} />
                </Suspense>
              </div>
              <div aria-hidden className="pointer-events-none absolute inset-x-0 bottom-14 h-16 bg-gradient-to-t from-surface to-transparent" />
              <ul aria-hidden className="absolute inset-x-0 bottom-0 flex h-14 items-center justify-around border-t border-border bg-surface/90 px-2 text-[10px] font-semibold text-muted backdrop-blur">
                {MOCK_NAV.map(([key, icon], i) => (
                  <li key={key} className={i === 0 ? 'flex flex-col items-center gap-0.5 text-ink' : 'flex flex-col items-center gap-0.5'}>
                    <span className={i === 0 ? 'grid h-6 w-10 place-items-center rounded-full bg-primary-soft-hover text-primary-soft-fg' : 'grid h-6 w-10 place-items-center'}>
                      <Icon name={icon} size={18} filled={i === 0} />
                    </span>
                    {t(`hero.mockNav.${key}`)}
                  </li>
                ))}
              </ul>
            </div>
          </figure>

          {/* HP: dua kartu jadi grid di bawah mockup; lg: melayang di tepi mockup (wrapper display: contents). */}
          <div className="mt-4 grid grid-cols-2 gap-3 lg:contents">
            <div className="surface-glass rounded-card p-4 shadow-pop lg:absolute lg:top-16 lg:-right-16 lg:w-[180px]">
              <p className="text-overline text-primary-soft-fg uppercase">{t('hero.cuanLabel')}</p>
              <p className="mt-1 text-body-s text-text-2 tnum">{t('hero.cuanViews', { views: n(EXAMPLE_VIEWS) })}</p>
              <p className="text-h5 text-ink tnum">{t('hero.cuanAmount', { amount: idr(earningFor(EXAMPLE_VIEWS, EXAMPLE_RATE)) })}</p>
              <p className="mt-1 text-caption text-muted">{t('hero.cuanNote', { rate: idr(EXAMPLE_RATE) })}</p>
            </div>
            <Suspense fallback={null}>
              <HeroTopRate />
            </Suspense>
          </div>

          <ul className="surface-glass mt-4 flex w-fit gap-1.5 rounded-full p-1.5 shadow-pop max-lg:mx-auto lg:absolute lg:bottom-0 lg:left-1/2 lg:mt-0 lg:-translate-x-1/2" aria-label={t('hero.platforms')}>
            {settings.platforms.map((p) => (
              <li key={p}>
                <PlatformChip platform={p} />
              </li>
            ))}
          </ul>
        </div>
      </Container>
    </section>
  );
}

async function HeroTopRate() {
  const [{ t, idr }, rate] = await Promise.all([ctx(), topLiveRate()]);
  if (rate == null) return null;
  return (
    <div className="surface-glass flex flex-col gap-3 rounded-card p-4 shadow-pop lg:absolute lg:bottom-28 lg:-left-28 lg:w-[214px] lg:flex-row lg:items-center lg:p-3.5">
      <span className="grid size-10 shrink-0 place-items-center rounded-[30%] bg-success-bg text-success">
        <Icon name="trending_up" size={22} />
      </span>
      <div className="min-w-0">
        <p className="text-caption text-muted">{t('hero.topRate')}</p>
        <p className="text-h6 whitespace-nowrap text-ink tnum">{t('hero.topRateValue', { rate: idr(rate) })}</p>
      </div>
    </div>
  );
}

export async function HowItWorks({ settings }: { settings: PublicSettings }) {
  const { t } = await ctx();
  const steps: Array<{ key: string; icon: IconName; values?: Record<string, string | number> }> = [
    { key: 's1', icon: 'campaign', values: { hours: settings.claimHours } },
    { key: 's2', icon: 'add_link', values: { max: settings.maxAccountsPerPlatform } },
    { key: 's3', icon: 'upload' },
    { key: 's4', icon: 'payments' },
  ];
  return (
    <Section id="cara-kerja" spacing="page" contained eyebrow={t('how.eyebrow')} title={t('how.title')} className="scroll-mt-16">
      <ol className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {steps.map((s, i) => (
          <StepCard key={s.key} n={i + 1} icon={s.icon} title={t(`how.${s.key}.title`)} body={t(`how.${s.key}.body`, s.values)} />
        ))}
      </ol>
    </Section>
  );
}

export async function Payout({ settings }: { settings: PublicSettings }) {
  const { t, idr } = await ctx();
  const items: Array<{ key: string; icon: IconName }> = [
    { key: 'pending', icon: 'hourglass_top' },
    { key: 'available', icon: 'check_circle' },
    { key: 'withdraw', icon: 'account_balance' },
    { key: 'kyc', icon: 'id_card' },
  ];
  return (
    <Section
      id="cara-bayar"
      tone="surface"
      spacing="page"
      eyebrow={t('payout.eyebrow')}
      title={t('payout.title')}
      description={t('payout.description')}
      className="scroll-mt-16"
    >
      <ol className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {items.map((s, i) => (
          <StepCard key={s.key} n={i + 1} icon={s.icon} title={t(`payout.${s.key}.title`)} body={t(`payout.${s.key}.body`, { min: idr(settings.minWithdrawIdr), days: settings.holdDays })} />
        ))}
      </ol>
    </Section>
  );
}

const FAQ_KEYS = ['followers', 'views', 'fee', 'payout', 'platforms', 'who', 'accounts'] as const;

export async function Faq({ settings }: { settings: PublicSettings }) {
  const { t, idr, locale } = await ctx();
  const platforms = new Intl.ListFormat(locale === 'en' ? 'en' : 'id', { type: 'conjunction' }).format(
    settings.platforms.map((p) => platformLabels[p]),
  );
  const values = { min: idr(settings.minWithdrawIdr), platforms, max: settings.maxAccountsPerPlatform };
  return (
    <Section id="faq" spacing="page" className="scroll-mt-16">
      <Container size="md">
        <div className="mb-8 flex flex-col gap-2">
          <p className="text-overline text-primary-soft-fg uppercase">{t('faq.eyebrow')}</p>
          <h2 className="text-h2 text-ink">{t('faq.title')}</h2>
        </div>
        <div className="surface-card divide-y divide-border rounded-card">
          {FAQ_KEYS.map((k) => (
            <details key={k} className="group">
              <summary className="flex min-h-14 cursor-pointer list-none items-center justify-between gap-4 rounded-card px-5 py-4 text-h6 text-ink focus-ring [&::-webkit-details-marker]:hidden">
                {t(`faq.items.${k}.q`)}
                <Icon name="expand_more" size={22} className="shrink-0 text-muted transition-transform duration-220 group-open:rotate-180" />
              </summary>
              <p className="px-5 pb-5 text-body text-text-2">{t(`faq.items.${k}.a`, values)}</p>
            </details>
          ))}
        </div>
      </Container>
    </Section>
  );
}

export async function ForBrand({ session, settings }: { session: boolean; settings: PublicSettings }) {
  const [{ t, idr, n }, fee] = await Promise.all([ctx(), globalFeeOrDefault()]);
  const cost = brandCost(10_000_000, fee.mgmt, fee.admin);
  const maxViews = Math.floor((cost.budget / EXAMPLE_RATE) * 1000);
  const ecpm = Math.round((cost.total / maxViews) * 1000);
  const steps: Array<{ key: string; icon: IconName }> = [
    { key: 'b1', icon: 'edit' },
    { key: 'b2', icon: 'receipt_long' },
    { key: 'b3', icon: 'verified' },
    { key: 'b4', icon: 'insights' },
  ];
  const href = brandHref(session);
  const row = (label: string, value: string, strong = false) => (
    <div className={strong ? 'flex items-baseline justify-between gap-4 border-t border-border pt-3 text-h6 text-ink' : 'flex items-baseline justify-between gap-4 text-body-s text-text-2'}>
      <dt>{label}</dt>
      <dd className="font-semibold tnum">{value}</dd>
    </div>
  );

  return (
    <Section
      id="brand"
      tone="dark"
      spacing="page"
      eyebrow={t('brand.eyebrow')}
      title={t('brand.title')}
      description={t('brand.body')}
      actions={
        <Button href={href} size="lg" iconRight="arrow_forward">
          {t('brand.start')}
        </Button>
      }
      className="scroll-mt-16"
    >
      <ol className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {steps.map((s, i) => (
          <StepCard key={s.key} n={i + 1} icon={s.icon} title={t(`brand.${s.key}.title`)} body={t(`brand.${s.key}.body`)} />
        ))}
      </ol>

      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card padding="lg" className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <h3 className="text-h5 text-ink">{t('brand.feeTitle')}</h3>
            <p className="text-body-s text-muted">{t('brand.feeBody', { mgmt: fee.mgmt, admin: fee.admin })}</p>
          </div>
          <div className="flex flex-col gap-2.5 rounded-card-sm bg-surface-2 p-4">
            <p className="text-overline text-muted uppercase">{t('brand.feeExample')}</p>
            <dl className="flex flex-col gap-2.5">
              {row(t('brand.feeBudget'), idr(cost.budget))}
              {row(t('brand.feeMgmt', { pct: fee.mgmt }), idr(cost.mgmt))}
              {row(t('brand.feeAdmin', { pct: fee.admin }), idr(cost.admin))}
              {row(t('brand.feeTotal'), idr(cost.total), true)}
            </dl>
          </div>
          <p className="text-caption text-muted">{t('brand.feeRate', { rate: idr(EXAMPLE_RATE), views: n(maxViews) })}</p>
        </Card>

        <Card padding="lg" className="flex flex-col gap-4">
          <div className="flex items-center justify-between gap-3">
            <h3 className="text-h5 text-ink">{t('brand.reportTitle')}</h3>
            <Badge tone="outline" size="sm">
              {t('brand.reportBadge')}
            </Badge>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <StatCard label={t('brand.reportViews')} value={n(maxViews)} icon="visibility" variant="tint" />
            <StatCard label={t('brand.reportClips')} value={n(1240)} icon="movie" variant="tint" />
            <StatCard label={t('brand.reportClippers')} value={n(318)} icon="groups" variant="tint" />
            <StatCard label={t('brand.reportEcpm')} value={idr(ecpm)} icon="trending_up" variant="tint" />
          </div>
          <p className="text-caption text-muted">{t('brand.reportNote')}</p>
        </Card>
      </div>

      <Card id="brand-managed" padding="lg" className="mt-4 flex scroll-mt-20 flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div className="flex items-start gap-4">
          <span className="grid size-11 shrink-0 place-items-center rounded-[30%] bg-primary-soft text-primary-soft-fg">
            <Icon name="support_agent" size={24} filled />
          </span>
          <div className="flex flex-col gap-1">
            <h3 className="text-h6 text-ink">{t('brand.managedTitle')}</h3>
            <p className="text-body-s text-muted">
              {settings.managedServiceIdr
                ? t('brand.managedNote', { price: idr(settings.managedServiceIdr) })
                : t('brand.managedNoteNoPrice')}
            </p>
          </div>
        </div>
        <Button href={href} variant="secondary" className="shrink-0">
          {t('brand.managed')}
        </Button>
      </Card>
    </Section>
  );
}

export async function CtaBand({ session }: { session: boolean }) {
  const { t } = await ctx();
  return (
    <Section tone="blue" spacing="page" contained title={t('ctaBand.title')} description={t('ctaBand.body')}>
      <Button href={clipperHref(session)} variant="inverse" size="lg" iconRight="arrow_forward">
        {session ? t('nav.openApp') : t('nav.start')}
      </Button>
    </Section>
  );
}
