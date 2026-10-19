import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { EmptyState, PageHeader, PLATFORMS, type Platform } from '@clipper/ui';
import { isUuid, param, rows, uniq, type SearchParams } from '@/lib/data';
import { ReviewQueue, type QueueItem } from '@/features/moderation/review-queue';
import { FilterBar } from '@/features/shared/filter-bar';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.review') };
}

const STATUSES = ['in_review', 'appealed'] as const;

// F-A05 / A4.1: antrean submisi in_review + appealed (filter campaign/platform/status), preview embed, histori banding.
export default async function ReviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  await requireAdmin(...rolesFor('review'));
  const [t, tc, sp, db] = await Promise.all([getTranslations('admin'), getTranslations('common'), searchParams, coreServer('admin')]);
  const campaign = param(sp, 'campaign');
  const platform = param(sp, 'platform');
  const status = param(sp, 'status');
  const statuses: (typeof STATUSES)[number][] = STATUSES.includes(status as never) ? [status as (typeof STATUSES)[number]] : [...STATUSES];

  let q = db.from('submissions').select('id, campaign_id, user_id, platform, url, status, counted_views, created_at')
    .in('status', statuses).order('created_at').limit(50);
  if (isUuid(campaign)) q = q.eq('campaign_id', campaign);
  if (PLATFORMS.includes(platform as Platform)) q = q.eq('platform', platform as Platform);
  const [subRes, campRes] = await Promise.all([
    q,
    db.from('submissions').select('campaign_id').in('status', [...STATUSES]).limit(1000),
  ]);
  const subs = rows(subRes);
  const ids = uniq(subs.map((s) => s.id));
  const campaignIds = uniq([...rows(campRes).map((s) => s.campaign_id), ...subs.map((s) => s.campaign_id)]);
  const [camps, profs, hist] = await Promise.all([
    db.from('campaigns').select('id, title').in('id', campaignIds),
    db.from('profiles').select('id, username').in('id', uniq(subs.map((s) => s.user_id))),
    ids.length
      ? db.from('review_decisions').select('target_id, decision, reason_code, message, created_at').eq('target_type', 'submission').in('target_id', ids).order('created_at')
      : Promise.resolve({ data: [], error: null }),
  ]);
  const title = new Map(rows(camps).map((c) => [c.id, c.title ?? '—']));
  const user = new Map(rows(profs).map((p) => [p.id, p.username ?? '—']));
  const history = rows(hist);
  const items: QueueItem[] = subs.map((s) => ({
    id: s.id!,
    url: s.url ?? '',
    platform: s.platform as Platform,
    status: s.status as QueueItem['status'],
    created_at: s.created_at!,
    campaign: title.get(s.campaign_id) ?? '—',
    username: user.get(s.user_id) ?? '—',
    views: Number(s.counted_views ?? 0),
    history: history
      .filter((h) => h.target_id === s.id)
      .map((h) => ({ decision: h.decision ?? '', reason: h.reason_code, message: h.message, at: h.created_at! })),
  }));
  const all = { value: 'all', label: t('common.all') };

  return (
    <>
      <PageHeader title={t('review.title')} description={t('review.description')} />
      <FilterBar
        submitLabel={t('form.apply')}
        resetHref="/review"
        resetLabel={t('form.reset')}
        filters={[
          { kind: 'select', name: 'campaign', label: t('review.campaign'), value: campaign, options: [all, ...campaignIds.map((id) => ({ value: id, label: title.get(id) ?? id }))] },
          { kind: 'select', name: 'platform', label: t('review.platform'), value: platform, options: [all, ...PLATFORMS.map((p) => ({ value: p, label: tc(`platforms.${p}`) }))] },
          { kind: 'select', name: 'status', label: t('review.status'), value: status, options: [all, ...STATUSES.map((s) => ({ value: s, label: t(`status.submission.${s}`) }))] },
        ]}
      />
      {items.length === 0 ? (
        <EmptyState icon="check_circle" tone="success" title={t('review.empty')} body={t('review.emptyBody')} />
      ) : (
        <ReviewQueue items={items} />
      )}
    </>
  );
}
