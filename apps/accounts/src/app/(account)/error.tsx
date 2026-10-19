'use client';

import { useTranslations } from 'next-intl';
import { Card, ErrorState } from '@clipper/ui';

export default function AccountError({ error, retry }: { error: unknown; retry: () => void }) {
  const t = useTranslations('common');
  const digest = error instanceof Error && 'digest' in error ? String(error.digest) : undefined;
  return (
    <Card>
      <ErrorState title={t('errorTitle')} body={t('errorBody')} action={{ label: t('retry'), onClick: retry }} code={digest} />
    </Card>
  );
}
