import type { ReactNode } from 'react';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Badge,
  Button,
  Card,
  Container,
  Icon,
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
import { brandCost } from './fees';

const EXAMPLE_VIEWS = 10_000;
const EXAMPLE_RATE = 2_000;

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

        <Card variant="blue" padding="lg" className="flex flex-col gap-4">
          <p className="text-overline uppercase opacity-80">{t('hero.cuanLabel')}</p>
          <p className="flex flex-col gap-1">
            <span className="text-h2 tnum">{t('hero.cuanViews', { views: n(EXAMPLE_VIEWS) })}</span>
            <span className="text-h1 tnum">{t('hero.cuanAmount', { amount: idr(earningFor(EXAMPLE_VIEWS, EXAMPLE_RATE)) })}</span>
          </p>
          <p className="text-body-s opacity-85">{t('hero.cuanNote', { rate: idr(EXAMPLE_RATE) })}</p>
          <ul className="flex flex-wrap gap-2" aria-label={t('hero.platforms')}>
            {settings.platforms.map((p) => (
              <li key={p}>
                <PlatformChip platform={p} tone="glass" />
              </li>
            ))}
          </ul>
        </Card>
      </Container>
    </section>
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
