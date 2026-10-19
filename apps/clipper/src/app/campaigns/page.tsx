import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import { Alert, EmptyState, ErrorState, type Platform } from '@clipper/ui';
import { categoryNames, fetchCampaignPage } from '@/features/campaigns/cards';
import { CampaignFeed } from '@/features/campaigns/feed';
import { FilterBar } from '@/features/campaigns/filter-bar';
import { filtersToQuery, isFiltered, parseFilters } from '@/features/campaigns/filters';
import { InstallBanner } from '@/features/pwa/install-banner';
import { enabledPlatforms } from '@/features/lib/pure';
import { core, readSettings } from '@/features/lib/server';

export const metadata: Metadata = { title: 'Campaign' };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

// F-C03 / C1.4: daftar campaign + CTA 6 state per user.
export default async function CampaignsPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const filters = parseFilters(await searchParams);
  const db = await core();
  const [t, page, categories, settings, social] = await Promise.all([
    getTranslations('clipper.campaigns'),
    fetchCampaignPage(filters, null),
    categoryNames(),
    readSettings(['public.flags.platforms']),
    db.from('social_accounts').select('id', { count: 'exact', head: true }).eq('user_id', claims.sub).eq('status', 'verified'),
  ]);
  const platforms = enabledPlatforms(settings['public.flags.platforms']) as Platform[];

  return (
    <div className="flex flex-col gap-4">
      <h1 className="text-h4 text-ink">{t('title')}</h1>
      {!social.count ? (
        <Alert
          tone="warn"
          title={t('connectTitle')}
          action={{ label: t('connectAction'), href: '/social?next=%2Fcampaigns', linkAs: Link }}
        >
          {t('connectBody')}
        </Alert>
      ) : null}
      <InstallBanner />
      <FilterBar filters={filters} platforms={platforms} categories={[...categories].map(([id, name]) => ({ id, name }))} />
      {!page.ok ? (
        <ErrorState compact title={t('loadError')} body={page.message} action={{ label: t('retry'), href: `/campaigns${filtersToQuery(filters)}`, linkAs: Link }} />
      ) : page.items.length === 0 ? (
        isFiltered(filters) ? (
          <EmptyState
            icon="search"
            tone="neutral"
            title={t('emptyFilteredTitle')}
            body={t('emptyFilteredBody')}
            action={{ label: t('reset'), href: '/campaigns', linkAs: Link }}
          />
        ) : (
          <EmptyState icon="campaign" title={t('emptyTitle')} body={t('emptyBody')} action={{ label: t('emptyAction'), href: '/social', linkAs: Link }} />
        )
      ) : (
        <CampaignFeed key={filtersToQuery(filters)} initial={page.items} next={page.next} filters={filters} />
      )}
    </div>
  );
}
