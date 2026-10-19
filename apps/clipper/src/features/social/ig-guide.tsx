import { getTranslations } from 'next-intl/server';
import { Button, Card, CardDescription, CardHeader, CardTitle } from '@clipper/ui';

/** F-C02 AC: akun IG personal ditolak + panduan pindah ke akun Creator (gratis). */
export async function IgGuide({ retryHref }: { retryHref: string }) {
  const t = await getTranslations('clipper.social.igGuide');
  return (
    <Card variant="tint">
      <CardHeader>
        <CardTitle>{t('title')}</CardTitle>
        <CardDescription>{t('body')}</CardDescription>
      </CardHeader>
      <ol className="ml-5 flex list-decimal flex-col gap-1.5 text-body-s text-text-2">
        {(['step1', 'step2', 'step3', 'step4'] as const).map((s) => (
          <li key={s}>{t(s)}</li>
        ))}
      </ol>
      <Button href={retryHref} className="mt-4" fullWidth iconLeft="refresh">
        {t('retry')}
      </Button>
    </Card>
  );
}
