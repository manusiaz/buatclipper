import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { EmptyState } from '@clipper/ui';

export default async function NotFound() {
  const t = await getTranslations('clipper');
  return (
    <EmptyState
      icon="explore"
      tone="neutral"
      title={t('notFound.title')}
      body={t('notFound.body')}
      action={{ label: t('notFound.action'), href: '/campaigns', linkAs: Link }}
    />
  );
}
