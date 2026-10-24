import { getLocale, getTranslations } from 'next-intl/server';
import { Button, CampaignCard, CampaignCardSkeleton, EmptyState, ErrorState, type UiLocale } from '@clipper/ui';
import { getCategories, type Category } from '@/lib/catalog';
import { cardCoverSrc } from '@/lib/core';
import { idrRates, maxViews, rulesFromJson } from '@/lib/rates';
import { num } from '@/lib/settings';
import { clipperHref } from '@/lib/session';
import { getLiveCampaigns, type LiveCampaign } from './data';

const GRID = 'grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 lg:gap-5';

export function CampaignGridSkeleton() {
  return (
    <div className={GRID} aria-hidden>
      {Array.from({ length: 3 }, (_, i) => (
        <CampaignCardSkeleton key={i} />
      ))}
    </div>
  );
}

function LiveCard({ c, session, categories, locale, cta }: { c: LiveCampaign; session: boolean; categories: Category[]; locale: UiLocale; cta: string }) {
  const href = clipperHref(session, `/campaigns/${c.id}`);
  const budget = num(c.budget_idr) ?? 0;
  const remaining = num(c.remaining_idr) ?? 0;
  const category = categories.find((k) => k.id === c.category_id);
  return (
    <CampaignCard
      className="w-full"
      title={c.title}
      href={href}
      coverSrc={cardCoverSrc(c.cover_path)}
      brand={c.brand_name ? { name: c.brand_name, verified: c.brand_verified } : undefined}
      category={category ? (locale === 'en' ? category.name_en : category.name_id) : undefined}
      platforms={c.platforms ?? []}
      rates={idrRates(rulesFromJson(c.rates), c.platforms ?? [])}
      pinned={c.is_pinned}
      isNew={c.is_new}
      deadline={c.submit_deadline ?? undefined}
      remainingViews={maxViews(c.est_remaining_views) ?? undefined}
      budgetUsedRatio={budget > 0 ? Math.min(1, Math.max(0, (budget - remaining) / budget)) : undefined}
      locale={locale}
      cta={
        <Button href={href} fullWidth iconRight="arrow_forward" className="relative z-10">
          {cta}
        </Button>
      }
    />
  );
}

/** Hero: campaign live teratas sebagai layar app di mockup HP (kartu yang sama dengan grid). Gagal/kosong → skeleton. */
export async function HeroCampaign({ session }: { session: boolean }) {
  const [t, locale] = await Promise.all([getTranslations('web.campaigns'), getLocale() as Promise<UiLocale>]);
  const [campaigns, categories] = await Promise.all([getLiveCampaigns().catch(() => []), getCategories().catch(() => [])]);
  const c = campaigns[0];
  return c ? <LiveCard c={c} session={session} categories={categories} locale={locale} cta={session ? t('open') : t('claim')} /> : <CampaignCardSkeleton />;
}

/** Hero: rate per 1.000 views tertinggi di antara campaign live terbaru (data asli, bukan angka contoh). */
export async function topLiveRate(): Promise<number | null> {
  const campaigns = await getLiveCampaigns().catch(() => []);
  const rates = campaigns.flatMap((c) => idrRates(rulesFromJson(c.rates), c.platforms ?? []).map((r) => r.ratePer1k));
  return rates.length ? Math.max(...rates) : null;
}

/** C1.1: kartu campaign live dari api.list_campaigns (anon). Tap kartu → login accounts dengan next ke detail di app. */
export async function CampaignGrid({ session }: { session: boolean }) {
  const [t, locale] = await Promise.all([getTranslations('web.campaigns'), getLocale() as Promise<UiLocale>]);
  let campaigns: LiveCampaign[];
  let categories: Category[] = [];
  try {
    [campaigns, categories] = await Promise.all([getLiveCampaigns(), getCategories().catch(() => [])]);
  } catch {
    return <ErrorState compact icon="wifi_off" title={t('errorTitle')} body={t('errorBody')} className="surface-card rounded-card" />;
  }

  if (!campaigns.length) {
    return (
      <EmptyState
        icon="campaign"
        title={t('emptyTitle')}
        body={t('emptyBody')}
        action={{ label: t('notify'), href: clipperHref(session) }}
        className="surface-card rounded-card"
      />
    );
  }

  return (
    <div className="flex flex-col items-center gap-8">
      <ul className={`${GRID} w-full`} aria-label={t('listLabel')}>
        {campaigns.map((c) => (
          <li key={c.id} className="flex min-w-0">
            <LiveCard c={c} session={session} categories={categories} locale={locale} cta={session ? t('open') : t('claim')} />
          </li>
        ))}
      </ul>
      <Button href={clipperHref(session)} variant="secondary" size="lg" iconRight="arrow_forward">
        {t('seeAll')}
      </Button>
    </div>
  );
}
