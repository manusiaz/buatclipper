import Link from 'next/link';
import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { EDITABLE_STATUSES } from '@clipper/campaign-builder';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  PageHeader,
  Pagination,
  ProgressBar,
  StatusBadge,
  Table,
  TBody,
  TD,
  TH,
  THead,
  TR,
  formatDate,
  formatIDR,
} from '@clipper/ui';
import { poolBudgets } from '@/features/campaigns/budget';
import { CampaignRowActions } from '@/features/campaigns/row-actions';
import { LinkTabs } from '@/features/shell/link-tabs';
import { can, getOrgContext } from '@/lib/org';

const PAGE = 20;

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('campaigns') };
}

export default async function CampaignsPage({
  params,
  searchParams,
}: {
  params: Promise<{ org: string }>;
  searchParams: Promise<{ tab?: string; page?: string }>;
}) {
  const [{ org: orgId }, sp] = await Promise.all([params, searchParams]);
  const { core, role } = await getOrgContext(orgId);
  const templates = sp.tab === 'templates';
  const page = Math.max(1, Number.parseInt(sp.page ?? '1', 10) || 1);
  const [t, locale, list, { count: tplCount }] = await Promise.all([
    getTranslations('brand'),
    getLocale(),
    core
      .from('campaigns')
      .select('id, title, type, status, is_template, service_mode, visibility, start_at, submit_deadline, pinned_until, created_at', { count: 'exact' })
      .eq('org_id', orgId)
      .eq('is_template', templates)
      .order('created_at', { ascending: false })
      .range((page - 1) * PAGE, page * PAGE - 1),
    core.from('campaigns').select('id', { count: 'exact', head: true }).eq('org_id', orgId).eq('is_template', true),
  ]);
  const loc = locale === 'en' ? 'en' : 'id';
  const rows = (list.data ?? []).filter((c): c is typeof c & { id: string } => !!c.id);
  const budgets = await poolBudgets(core, rows.map((r) => r.id));
  const pageCount = Math.max(1, Math.ceil((list.count ?? 0) / PAGE));
  const edit = can(role, 'edit');
  const base = `/${orgId}/campaigns`;
  const now = Date.now();

  return (
    <>
      <PageHeader
        title={t('campaigns.title')}
        description={t('campaigns.description')}
        actions={edit ? <Button href={`${base}/new`} linkAs={Link} iconLeft="add">{t('campaigns.create')}</Button> : null}
      />
      <div className="mb-4">
        <LinkTabs
          label={t('campaigns.tabsLabel')}
          items={[
            { href: base, label: t('campaigns.tabCampaigns'), active: !templates, icon: 'campaign' },
            { href: `${base}?tab=templates`, label: t('campaigns.tabTemplates'), active: templates, icon: 'bookmark', count: tplCount ?? 0 },
          ]}
        />
      </div>
      {rows.length === 0 ? (
        <Card padding="lg">
          <EmptyState
            icon={templates ? 'bookmark' : 'campaign'}
            title={templates ? t('campaigns.emptyTemplatesTitle') : t('campaigns.emptyTitle')}
            body={templates ? t('campaigns.emptyTemplatesBody') : t('campaigns.emptyBody')}
            action={edit && !templates ? { label: t('campaigns.create'), href: `${base}/new`, linkAs: Link, icon: 'add' } : undefined}
          />
        </Card>
      ) : (
        <Table
          caption={templates ? t('campaigns.tabTemplates') : t('campaigns.tabCampaigns')}
          footer={
            pageCount > 1 ? (
              <Pagination
                page={page}
                pageCount={pageCount}
                linkAs={Link}
                getHref={(p) => `${base}?${new URLSearchParams({ ...(templates ? { tab: 'templates' } : {}), page: String(p) })}`}
                labels={{ nav: t('common.pagination'), previous: t('common.previous'), next: t('common.next') }}
              />
            ) : undefined
          }
        >
          <THead>
            <TR>
              <TH>{t('campaigns.colCampaign')}</TH>
              <TH>{t('campaigns.colStatus')}</TH>
              <TH align="right">{t('campaigns.colBudget')}</TH>
              <TH>{t('campaigns.colDeadline')}</TH>
              <TH align="right"><span className="sr-only">{t('campaigns.colActions')}</span></TH>
            </TR>
          </THead>
          <TBody>
            {rows.map((c) => {
              const editable = EDITABLE_STATUSES.includes(c.status ?? 'draft');
              const href = templates || editable ? `${base}/new?campaign=${c.id}` : `${base}/${c.id}`;
              const b = budgets.get(c.id);
              const pinned = c.pinned_until && new Date(c.pinned_until).getTime() > now;
              return (
                <TR key={c.id}>
                  <TD>
                    <div className="flex max-w-[min(360px,60vw)] flex-col gap-1">
                      <Link href={href} className="truncate font-bold text-ink hover:text-link focus-ring rounded-[4px]">
                        {c.title || t('campaigns.untitled')}
                      </Link>
                      <span className="flex flex-wrap items-center gap-1.5 text-caption text-muted">
                        {t(`campaignType.${c.type ?? 'clipping'}`)}
                        {c.service_mode === 'managed' ? <Badge size="sm" tone="premium">{t('campaigns.managed')}</Badge> : null}
                        {c.visibility === 'invite' ? <Badge size="sm" tone="outline" icon="lock">{t('campaigns.private')}</Badge> : null}
                        {pinned ? <Badge size="sm" tone="primary" icon="push_pin">{t('campaigns.pinned')}</Badge> : null}
                      </span>
                    </div>
                  </TD>
                  <TD>
                    {templates ? (
                      <Badge tone="outline" icon="bookmark">{t('campaigns.template')}</Badge>
                    ) : (
                      <StatusBadge kind="campaign" status={c.status ?? 'draft'} label={t(`campaignStatus.${c.status ?? 'draft'}`)} />
                    )}
                  </TD>
                  <TD numeric>
                    {b && b.budget > 0 ? (
                      <div className="ml-auto flex w-40 flex-col items-end gap-1.5">
                        <span className="font-semibold text-ink">{formatIDR(b.budget, { locale: loc })}</span>
                        <ProgressBar
                          value={Math.min(100, (b.used / b.budget) * 100)}
                          size="sm"
                          label={t('campaigns.usedLabel')}
                          className="w-full"
                        />
                      </div>
                    ) : (
                      <span className="text-muted">—</span>
                    )}
                  </TD>
                  <TD muted>{c.submit_deadline ? formatDate(c.submit_deadline, loc) : '—'}</TD>
                  <TD align="right">
                    <CampaignRowActions
                      orgId={orgId}
                      id={c.id}
                      title={c.title ?? ''}
                      isTemplate={!!c.is_template}
                      editable={editable}
                      canEdit={edit}
                    />
                  </TD>
                </TR>
              );
            })}
          </TBody>
        </Table>
      )}
    </>
  );
}
