import { getTranslations } from 'next-intl/server';
import { Button, Card, CardDescription, CardHeader, CardTitle } from '@clipper/ui';

/** Facebook page_ambiguous: pilih satu Page → authorize ulang dengan page_id (code OAuth sekali pakai). */
export async function PagePicker({ pages, next }: { pages: { id: string; name: string }[]; next?: string }) {
  const t = await getTranslations('clipper.social');
  return (
    <Card variant="raised">
      <CardHeader>
        <CardTitle>{t('pickPageTitle')}</CardTitle>
        <CardDescription>{t('pickPageBody')}</CardDescription>
      </CardHeader>
      <ul className="flex flex-col gap-2">
        {pages.map((p) => {
          const q = new URLSearchParams({ page_id: p.id });
          if (next) q.set('next', next);
          return (
            <li key={p.id}>
              <Button href={`/api/oauth/facebook/start?${q}`} variant="secondary" fullWidth iconRight="arrow_forward" className="justify-between">
                {p.name || p.id}
              </Button>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}
