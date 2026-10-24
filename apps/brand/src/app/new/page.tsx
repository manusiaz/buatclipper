import Link from 'next/link';
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { requireBrand } from '@clipper/auth/server';
import { Breadcrumb, PageHeader } from '@clipper/ui';
import { CreateOrgForm } from '@/features/org/create-org-form';
import { PlainShell } from '@/features/shell/plain-shell';
import { myName } from '@/features/shell/me';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.newOrg'))('title') };
}

export default async function NewOrgPage() {
  const { claims } = await requireBrand();
  const [t, name] = await Promise.all([getTranslations('brand'), myName(claims.email)]);
  return (
    <PlainShell name={name} email={claims.email}>
      <div className="mx-auto max-w-[680px]">
        <PageHeader
          title={t('newOrg.title')}
          description={t('newOrg.description')}
          breadcrumb={<Breadcrumb linkAs={Link} items={[{ label: t('picker.title'), href: '/' }, { label: t('newOrg.title') }]} />}
        />
        <CreateOrgForm kycApproved={claims.kyc === 'approved'} />
      </div>
    </PlainShell>
  );
}
