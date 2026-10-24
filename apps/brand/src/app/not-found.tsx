import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { Card, EmptyState } from '@clipper/ui';

export default async function NotFound() {
  const t = await getTranslations('brand');
  return (
    <Card padding="lg" className="mx-auto my-10 max-w-[640px]">
      <EmptyState icon="search" title={t('notFound.title')} body={t('notFound.body')} action={{ label: t('notFound.action'), href: '/', linkAs: Link }} />
    </Card>
  );
}
