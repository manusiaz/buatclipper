import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Container, EmptyState } from '@clipper/ui';

export const metadata: Metadata = { robots: { index: false, follow: false } };

export default async function ReportInvalid() {
  const t = await getTranslations('web.report');
  return (
    <Container size="sm" className="py-16">
      <EmptyState
        icon="link_off"
        tone="warn"
        title={t('invalidTitle')}
        body={t('invalidBody')}
        action={{ label: t('home'), href: '/' }}
        className="surface-card rounded-card"
      />
    </Container>
  );
}
