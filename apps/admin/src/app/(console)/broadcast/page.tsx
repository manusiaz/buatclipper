import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Badge, Card, CardHeader, CardTitle, EmptyState, formatDateTime, formatNumber, PageHeader, type UiLocale } from '@clipper/ui';
import { rows } from '@/lib/data';
import { BroadcastForm } from '@/features/broadcast/broadcast-form';
import { PLATFORM_KEYS, type Segment } from '@/features/broadcast/segment';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.broadcast') };
}

// F-A12 / A6.1: tulis + jadwalkan broadcast ke segmen clipper; daftar ops.broadcasts dengan jumlah penerima.
export default async function BroadcastPage() {
  await requireAdmin(...rolesFor('broadcast'));
  const [t, tc, locale, db] = await Promise.all([getTranslations('admin'), getTranslations('common'), getLocale(), coreServer('admin')]);
  const loc = locale as UiLocale;
  const list = rows(await db.from('broadcasts').select('id, title, body, segment, channels, scheduled_at, sent_at, recipient_count').order('scheduled_at', { ascending: false }).limit(50));
  const platformLabels = Object.fromEntries(PLATFORM_KEYS.map((p) => [p, tc(`platforms.${p}`)]));
  const segText = (s: Segment) => {
    const parts = [
      s.platforms?.length ? s.platforms.map((p) => platformLabels[p] ?? p).join(', ') : null,
      s.min_trust_score != null || s.max_trust_score != null ? `Trust ${s.min_trust_score ?? 0}–${s.max_trust_score ?? 100}` : null,
      s.kyc ? t(s.kyc === 'approved' ? 'broadcast.kycApproved' : 'broadcast.kycNotApproved') : null,
      s.active_days ? t('broadcast.activeDaysShort', { n: s.active_days }) : null,
    ].filter(Boolean);
    return parts.length ? parts.join(' · ') : t('broadcast.everyone');
  };

  return (
    <>
      <PageHeader title={t('broadcast.title')} description={t('broadcast.description')} />
      <div className="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <Card padding="lg">
          <BroadcastForm platformLabels={platformLabels} />
        </Card>
        <Card padding="none">
          <CardHeader className="px-5 pt-5">
            <CardTitle>{t('broadcast.history')}</CardTitle>
          </CardHeader>
          {list.length === 0 ? (
            <EmptyState compact icon="send" tone="neutral" title={t('broadcast.empty')} className="pb-8" />
          ) : (
            <ul className="mt-2 divide-y divide-border">
              {list.map((b) => (
                <li key={b.id} className="flex flex-col gap-1.5 px-5 py-4">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-semibold break-words text-ink">{b.title}</span>
                    {b.sent_at ? (
                      <Badge tone="success">{t('broadcast.sentTo', { n: formatNumber(b.recipient_count ?? 0, loc) })}</Badge>
                    ) : (
                      <Badge tone="warn" dot="pulse">{t('broadcast.pending')}</Badge>
                    )}
                  </div>
                  <p className="line-clamp-2 text-body-s text-text-2">{b.body}</p>
                  <p className="text-caption text-muted">
                    {segText((b.segment ?? {}) as Segment)} · {(b.channels ?? []).map((c) => t(`broadcast.channel.${c}`)).join(', ')}
                  </p>
                  <p className="text-caption text-faint">
                    {formatDateTime(b.sent_at ?? b.scheduled_at!, loc)}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </>
  );
}
