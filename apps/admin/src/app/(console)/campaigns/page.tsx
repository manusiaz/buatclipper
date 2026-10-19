import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Badge, Button, EmptyState, PageHeader, PlatformChip, RelativeTime, Table, TBody, TD, TH, THead, TR, type Platform, type UiLocale } from '@clipper/ui';
import { isUuid, param, rows, uniq, type SearchParams } from '@/lib/data';
import { ManagedQueue } from '@/features/campaign-review/managed-queue';
import { ReviewDetail } from '@/features/campaign-review/review-detail';
import { TabLinks } from '@/features/shared/tab-links';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.campaigns') };
}

// F-A02 antrean review campaign (in_review) + F-A03 tab Paket managed (J-A7 A7.1).
export default async function CampaignsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  await requireAdmin(...rolesFor('campaigns'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const tab = param(sp, 'tab') === 'managed' ? 'managed' : 'review';
  const id = param(sp, 'id');

  const [reviewRes, managedCount] = await Promise.all([
    db.from('campaigns').select('id, org_id, title, type, platforms, service_mode, created_at').eq('status', 'in_review').order('created_at').limit(100),
    db.from('campaigns').select('id', { count: 'exact', head: true }).eq('service_mode', 'managed').eq('status', 'draft'),
  ]);
  const queue = rows(reviewRes);

  return (
    <>
      <PageHeader
        title={t('campaigns.title')}
        description={t('campaigns.description')}
        actions={
          <Button href="/campaigns/new" linkAs={Link} iconLeft="add">
            {t('campaigns.newForOrg')}
          </Button>
        }
      />
      <TabLinks
        label={t('campaigns.title')}
        active={tab}
        tabs={[
          { key: 'review', href: '/campaigns', label: t('campaigns.tabReview'), icon: 'checklist', count: queue.length },
          { key: 'managed', href: '/campaigns?tab=managed', label: t('campaigns.tabManaged'), icon: 'support_agent', count: managedCount.count ?? 0 },
        ]}
      />
      {tab === 'managed' ? (
        <ManagedQueue loc={loc} />
      ) : (
        <>
          {isUuid(id) ? <ReviewDetail id={id} loc={loc} /> : null}
          <ReviewTable queue={queue} loc={loc} selected={id} />
        </>
      )}
    </>
  );
}

async function ReviewTable({ queue, loc, selected }: {
  queue: { id: string | null; org_id: string | null; title: string | null; type: string | null; platforms: string[] | null; service_mode: string | null; created_at: string | null }[];
  loc: UiLocale;
  selected: string;
}) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  if (queue.length === 0) return <EmptyState icon="check_circle" tone="success" title={t('campaigns.reviewEmpty')} body={t('campaigns.reviewEmptyBody')} />;
  const ids = uniq(queue.map((c) => c.id));
  const [orgs, invoices] = await Promise.all([
    db.from('organizations').select('id, name').in('id', uniq(queue.map((c) => c.org_id))),
    db.from('invoices').select('campaign_id, status').eq('kind', 'campaign').neq('status', 'void').in('campaign_id', ids),
  ]);
  const orgName = new Map(rows(orgs).map((o) => [o.id, o.name]));
  const paid = new Set(rows(invoices).filter((i) => i.status === 'paid').map((i) => i.campaign_id));

  return (
    <Table card caption={t('campaigns.tabReview')}>
      <THead>
        <TR>
          <TH>{t('campaigns.col.campaign')}</TH>
          <TH>{t('campaigns.col.org')}</TH>
          <TH className="hidden md:table-cell">{t('campaigns.col.platforms')}</TH>
          <TH>{t('campaigns.col.invoice')}</TH>
          <TH align="right">{t('campaigns.col.submitted')}</TH>
        </TR>
      </THead>
      <TBody>
        {queue.map((c) => (
          <TR key={c.id} selected={c.id === selected} interactive>
            <TD>
              <Link href={`/campaigns?id=${c.id}`} className="font-semibold break-words text-ink hover:text-link focus-ring">
                {c.title}
              </Link>
              {c.service_mode === 'managed' ? <Badge tone="outline" size="sm" className="ml-2">{t('campaigns.serviceMode.managed')}</Badge> : null}
            </TD>
            <TD muted>{orgName.get(c.org_id) ?? '—'}</TD>
            <TD className="hidden md:table-cell">
              <div className="flex flex-wrap gap-1">
                {(c.platforms ?? []).map((p) => (
                  <PlatformChip key={p} platform={p as Platform} />
                ))}
              </div>
            </TD>
            <TD>
              {paid.has(c.id) ? (
                <Badge tone="success">{t('finance.invoiceStatus.paid')}</Badge>
              ) : (
                <Badge tone="warn">{t('finance.invoiceStatus.issued')}</Badge>
              )}
            </TD>
            <TD align="right" muted>
              <RelativeTime value={c.created_at!} locale={loc} />
            </TD>
          </TR>
        ))}
      </TBody>
    </Table>
  );
}
