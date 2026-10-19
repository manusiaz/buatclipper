'use client';

import { useTranslations } from 'next-intl';
import { ErrorState } from '@clipper/ui';

export default function RouteError({ error, retry }: { error: unknown; retry: () => void }) {
  const t = useTranslations('common');
  const digest = error instanceof Error && 'digest' in error ? String((error as Error & { digest?: string }).digest ?? '') : '';
  return (
    <ErrorState
      title={t('errorTitle')}
      body={t('errorBody')}
      code={digest || undefined}
      action={{ label: t('retry'), onClick: retry, icon: 'refresh' }}
    />
  );
}
