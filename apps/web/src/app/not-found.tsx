import { getTranslations } from 'next-intl/server';
import { Container, EmptyState } from '@clipper/ui';

export default async function NotFound() {
  const t = await getTranslations('web.notFound');
  return (
    <Container size="sm" className="py-16">
      <EmptyState icon="explore" title={t('title')} body={t('body')} action={{ label: t('home'), href: '/' }} className="surface-card rounded-card" />
    </Container>
  );
}
