import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getLocale, getTranslations } from 'next-intl/server';
import { formatIDR, type UiLocale } from '@clipper/ui';
import { categoryName } from '@/lib/catalog';
import { idrRates } from '@/lib/rates';
import { hasSession } from '@/lib/session';
import { plainExcerpt } from '@/lib/text';
import { CampaignView } from '@/features/campaign-public/campaign-view';
import { getPublicCampaign } from '@/features/campaign-public/data';

type Props = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const data = await getPublicCampaign(slug);
  if (!data) notFound();
  const [t, locale] = await Promise.all([getTranslations('web.campaign'), getLocale() as Promise<UiLocale>]);
  const c = data.campaign;
  const top = Math.max(0, ...idrRates(data.rules, c.platforms).map((r) => r.ratePer1k));
  const description =
    plainExcerpt(c.brief) ||
    (top > 0 ? t('metaRate', { title: c.title, rate: formatIDR(top, { locale }) }) : t('metaDefault', { title: c.title }));
  return {
    title: c.title,
    description,
    alternates: { canonical: `/c/${c.slug}` },
    openGraph: { type: 'website', title: c.title, description, url: `/c/${c.slug}` },
    twitter: { card: 'summary_large_image', title: c.title, description },
  };
}

// Tanpa loading.tsx: data di-cache 60 dtk, dan notFound() sebelum flush pertama = status 404 sungguhan untuk SEO.
export default async function PublicCampaignPage({ params }: Props) {
  const { slug } = await params;
  const [data, session, locale] = await Promise.all([getPublicCampaign(slug), hasSession(), getLocale()]);
  if (!data) notFound();
  return <CampaignView data={data} session={session} category={await categoryName(data.campaign.category_id, locale)} />;
}
