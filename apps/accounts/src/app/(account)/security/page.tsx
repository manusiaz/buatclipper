import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { mfaStatus } from '@clipper/auth/actions';
import { requireAccount } from '@clipper/auth/server';
import { Card, Icon, PageHeader } from '@clipper/ui';
import { MfaSection } from '@/features/security/mfa-section';
import { one, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('security') };
}

export default async function SecurityPage({ searchParams }: { searchParams: SearchParams }) {
  await requireAccount();
  const next = one((await searchParams).next);
  const [t, mfa] = await Promise.all([getTranslations('accounts.security'), mfaStatus('sso')]);

  return (
    <div className="flex flex-col gap-5">
      <PageHeader title={t('title')} description={t('description')} />
      <Card padding="lg">
        <MfaSection enrolled={mfa.enrolled} aal={mfa.aal} next={next} />
      </Card>
      <Card variant="tint" className="flex items-start gap-3">
        <Icon name="support_agent" size={22} filled className="mt-0.5 shrink-0 text-primary-soft-fg" />
        <p className="text-body-s text-text-2">{t('lost')}</p>
      </Card>
    </div>
  );
}
