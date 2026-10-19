'use client';

import { useTranslations } from 'next-intl';
import { Card, ErrorState } from '@clipper/ui';

export function RouteError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const t = useTranslations('common');
  return (
    <Card padding="lg" className="mx-auto my-6 max-w-[640px]">
      <ErrorState
        title={t('errorTitle')}
        body={t('errorBody')}
        code={error.digest}
        action={{ label: t('retry'), onClick: reset, icon: 'refresh' }}
        secondaryAction={{ label: t('back'), href: '/' }}
      />
    </Card>
  );
}
