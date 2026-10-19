import Link from 'next/link';
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { Alert, Card, EmptyState, PageHeader, Pagination } from '@clipper/ui';
import { brandReviewCampaigns } from '@/features/review/queries';
import { ReviewQueue, type QueueItem } from '@/features/review/review-queue';
import { can, getOrgContext } from '@/lib/org';

const PAGE = 30;
// market.brand_review_auto_approve_hours bukan config publik; default job = 72 jam.
const AUTO_HOURS = 72;

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('review') };
}

export default async function ReviewPage({ params, searchParams }: { params: Promise<{ org: string }>; searchParams: Promise<{ page?: string }> }) {
  const [{ org: orgId }, sp] = await Promise.all([params, searchParams]);
  const { core, role } = await getOrgContext(orgId);
  const t = await getTranslations('brand');
  const page = Math.max(1, Number.parseInt(sp.page ?? '1', 10) || 1);
  const campaigns = await brandReviewCampaigns(core, orgId);
  const titles = new Map(campaigns.map((c) => [c.id, c.title]));

  const { data: subs, count } = campaigns.length
    ? await core
        .from('submissions')
        .select('id, user_id, campaign_id, platform, url, created_at', { count: 'exact' })
        .in('campaign_id', campaigns.map((c) => c.id))
        .eq('status', 'in_review')
        .order('created_at')
        .range((page - 1) * PAGE, page * PAGE - 1)
    : { data: [], count: 0 };
  const userIds = [...new Set((subs ?? []).map((s) => s.user_id).filter((x): x is string => !!x))];
  const { data: profiles } = userIds.length ? await core.from('profiles').select('id, username').in('id', userIds) : { data: [] };
  const names = new Map((profiles ?? []).map((p) => [p.id, p.username ?? '']));
  const items: QueueItem[] = (subs ?? []).flatMap((s) =>
    s.id && s.url && s.created_at
      ? [{
          id: s.id,
          campaignTitle: titles.get(s.campaign_id ?? '') ?? '',
          username: names.get(s.user_id ?? '') ?? '',
          platform: s.platform ?? '',
          url: s.url,
          createdAt: s.created_at,
          autoApproveAt: new Date(new Date(s.created_at).getTime() + AUTO_HOURS * 3600_000).toISOString(),
        }]
      : [],
  );
  const pageCount = Math.max(1, Math.ceil((count ?? 0) / PAGE));

  return (
    <>
      <PageHeader title={t('review.title')} description={t('review.description', { hours: AUTO_HOURS })} />
      {!can(role, 'review') ? <Alert tone="info" className="mb-4">{t('review.readOnly')}</Alert> : null}
      {campaigns.length === 0 ? (
        <Card padding="lg">
          <EmptyState icon="checklist" title={t('review.noCampaignsTitle')} body={t('review.noCampaignsBody')} />
        </Card>
      ) : items.length === 0 ? (
        <Card padding="lg">
          <EmptyState icon="check_circle" tone="success" title={t('review.emptyTitle')} body={t('review.emptyBody')} />
        </Card>
      ) : (
        <>
          <ReviewQueue orgId={orgId} items={items} canReview={can(role, 'review')} />
          {pageCount > 1 ? (
            <Pagination
              className="mt-4"
              page={page}
              pageCount={pageCount}
              linkAs={Link}
              getHref={(p) => `/${orgId}/review?page=${p}`}
              labels={{ nav: t('common.pagination'), previous: t('common.previous'), next: t('common.next') }}
            />
          ) : null}
        </>
      )}
    </>
  );
}
