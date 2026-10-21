import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import { Button, Card, Countdown, EmptyState } from '@clipper/ui';
import { sharedUrl } from '@clipper/clipper-lib/pure';
import { core, uiLocale } from '@/features/lib/server';

export const metadata: Metadata = { title: 'Kirim clip' };

type Props = { searchParams: Promise<{ url?: string; text?: string; title?: string }> };

// Share target PWA (manifest share_target, DS Android/iOS 01: "share sheet buat kirim clip"): link dari app sosmed →
// pilih claim terbuka → detail campaign dengan sheet Submit terbuka dan link terisi (tetap dicek ke API, F-C06).
export default async function SharePage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const [t, locale, sp, db] = await Promise.all([getTranslations('clipper'), uiLocale(), searchParams, core()]);
  const url = sharedUrl(sp);
  if (!url) {
    return <EmptyState icon="link_off" title={t('share.badTitle')} body={t('share.badBody')} action={{ label: t('share.browse'), href: '/campaigns' }} className="surface-card rounded-card" />;
  }

  const open =
    (
      await db
        .from('claims')
        .select('id,campaign_id,expires_at')
        .eq('user_id', claims.sub)
        .eq('status', 'open')
        .gt('expires_at', new Date().toISOString())
        .order('expires_at')
    ).data ?? [];
  if (!open.length) {
    return <EmptyState icon="campaign" title={t('share.emptyTitle')} body={t('share.emptyBody')} action={{ label: t('share.browse'), href: '/campaigns' }} className="surface-card rounded-card" />;
  }
  const titles = new Map(
    ((await db.from('campaigns').select('id,title').in('id', open.map((c) => c.campaign_id!))).data ?? []).map((c) => [c.id, c.title]),
  );

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <p className="text-body-s text-text-2">{t('share.body')}</p>
        <p className="truncate rounded-control bg-surface-2 px-3 py-2 text-caption text-muted">{url}</p>
      </div>
      <ul className="flex flex-col gap-2">
        {open.map((c) => (
          <li key={c.id}>
            <Card padding="sm" className="flex flex-col gap-2">
              <p className="line-clamp-2 text-body-s font-bold text-ink">{titles.get(c.campaign_id) ?? t('tasks.campaign')}</p>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="flex items-center gap-1 text-caption text-muted">
                  {t('claim.expiresIn')}
                  <Countdown target={c.expires_at!} locale={locale} withIcon expiredLabel={t('claim.expired')} className="text-ink" />
                </p>
                <Button size="sm" variant="ink" iconLeft="upload" href={`/campaigns/${c.campaign_id}?submit=1&url=${encodeURIComponent(url)}`} linkAs={Link}>
                  {t('share.pick')}
                </Button>
              </div>
            </Card>
          </li>
        ))}
      </ul>
    </div>
  );
}
