import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { hosts, onboardingUrl } from '@clipper/auth';
import { coreServer, requireAccount } from '@clipper/auth/server';
import { Card, CardDescription, CardHeader, CardTitle, PageHeader } from '@clipper/ui';
import { consentSummary } from '@/features/privacy/consents';
import { ConsentList, DeleteAccount, DownloadData } from '@/features/privacy/privacy-panels';
import { identityDb } from '@/lib/identity';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('privacy') };
}

export default async function PrivacyPage() {
  const { claims } = await requireAccount();
  const [t, id, core] = await Promise.all([getTranslations('accounts.privacy'), identityDb(), coreServer()]);
  const [consents, profile] = await Promise.all([
    id.from('my_consents').select('kind, version, granted_at, revoked_at'),
    core.from('my_profile').select('username').maybeSingle(),
  ]);
  if (consents.error) throw new Error(consents.error.message);
  const back = `${hosts.accounts}/privacy`;

  return (
    <div className="flex flex-col gap-5">
      <PageHeader title={t('title')} description={t('description')} />

      <Card padding="lg">
        <CardHeader>
          <CardTitle>{t('consentsTitle')}</CardTitle>
          <CardDescription>{t('consentsDescription')}</CardDescription>
        </CardHeader>
        <ConsentList
          items={consentSummary(consents.data ?? [])}
          reconsentHref={{ clipper: onboardingUrl('clipper', back), brand: onboardingUrl('brand', back) }}
        />
      </Card>

      <Card padding="lg">
        <CardHeader actions={<DownloadData />} className="mb-0 flex-col sm:flex-row">
          <CardTitle>{t('downloadTitle')}</CardTitle>
          <CardDescription>{t('downloadDescription')}</CardDescription>
        </CardHeader>
      </Card>

      <Card padding="lg" className="border border-danger-border">
        <CardHeader actions={<DeleteAccount confirmText={profile.data?.username ?? claims.email ?? 'HAPUS'} />} className="mb-0 flex-col sm:flex-row">
          <CardTitle>{t('deleteTitle')}</CardTitle>
          <CardDescription>{t('deleteDescription')}</CardDescription>
        </CardHeader>
      </Card>
    </div>
  );
}
