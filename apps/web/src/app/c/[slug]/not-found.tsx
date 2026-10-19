import { getTranslations } from 'next-intl/server';
import { Container, EmptyState } from '@clipper/ui';

export default async function CampaignNotFound() {
  const t = await getTranslations('web.campaign');
  return (
    <Container size="sm" className="py-16">
      <EmptyState
        icon="search"
        title={t('notFoundTitle')}
        body={t('notFoundBody')}
        action={{ label: t('seeOthers'), href: '/#campaigns' }}
        className="surface-card rounded-card"
      />
    </Container>
  );
}
