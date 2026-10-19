'use client';

import { useTranslations } from 'next-intl';
import { Container, ErrorState } from '@clipper/ui';

export default function Error({ error, retry }: { error: unknown; retry: () => void }) {
  const t = useTranslations('common');
  const digest = error instanceof Error && 'digest' in error ? String((error as Error & { digest?: string }).digest ?? '') : '';
  return (
    <Container size="sm" className="py-16">
      <ErrorState
        title={t('errorTitle')}
        body={t('errorBody')}
        action={{ label: t('retry'), onClick: retry }}
        code={digest || undefined}
        className="surface-card rounded-card"
      />
    </Container>
  );
}
