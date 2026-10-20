import { Suspense } from 'react';
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { HomeBanners, Section } from '@clipper/ui';
import { settingsOrDefault } from '@/lib/catalog';
import { hasSession } from '@/lib/session';
import { CampaignGrid, CampaignGridSkeleton } from '@/features/landing/campaign-grid';
import { CtaBand, Faq, ForBrand, Hero, HowItWorks, Payout } from '@/features/landing/sections';

export const metadata: Metadata = { alternates: { canonical: '/' } };

/** C1.1 landing + B1.1 #brand (§6.1, §6.4). Server render penuh; kartu campaign di-stream supaya hero (LCP) tidak menunggu DB. */
export default async function LandingPage() {
  const [t, session, settings] = await Promise.all([getTranslations('web.campaigns'), hasSession(), settingsOrDefault()]);
  return (
    <>
      <Hero session={session} settings={settings} />
      <Section id="campaigns" spacing="page" contained eyebrow={t('eyebrow')} title={t('title')} description={t('description')} className="scroll-mt-16 pt-4 md:pt-8">
        <HomeBanners banners={settings.banners} className="mb-6" />
        <Suspense fallback={<CampaignGridSkeleton />}>
          <CampaignGrid session={session} />
        </Suspense>
      </Section>
      <HowItWorks settings={settings} />
      <Payout settings={settings} />
      <ForBrand session={session} settings={settings} />
      <Faq settings={settings} />
      <CtaBand session={session} />
    </>
  );
}
