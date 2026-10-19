'use client';

import { useTranslations } from 'next-intl';
import { AuthShell, ErrorState } from '@clipper/ui';

export default function AuthError({ error, retry }: { error: unknown; retry: () => void }) {
  const t = useTranslations('common');
  const digest = error instanceof Error && 'digest' in error ? String(error.digest) : undefined;
  return (
    <AuthShell>
      <ErrorState compact title={t('errorTitle')} body={t('errorBody')} action={{ label: t('retry'), onClick: retry }} code={digest} />
    </AuthShell>
  );
}
