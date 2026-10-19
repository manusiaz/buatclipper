'use client';

import { useTranslations } from 'next-intl';
import { ErrorState } from '@clipper/ui';

export default function ConsoleError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const t = useTranslations('common');
  return (
    <ErrorState
      title={t('errorTitle')}
      body={t('errorBody')}
      code={error.digest}
      action={{ label: t('retry'), onClick: reset, icon: 'refresh' }}
      className="mt-10"
    />
  );
}
