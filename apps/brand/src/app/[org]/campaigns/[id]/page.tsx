import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getLocale, getTranslations } from 'next-intl/server';
import { EDITABLE_STATUSES } from '@clipper/campaign-builder';
import {
  Alert,
  Badge,
  Breadcrumb,
  Button,
  PageHeader,
  StatusBadge,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  formatDateTime,
} from '@clipper/ui';
import { ControlPanel, type ControlRule } from '@/features/controls/control-panel';
import { PinPanel } from '@/features/controls/pin-panel';
import { Overview } from '@/features/dashboard/overview';
import { parseStats } from '@/features/dashboard/stats';
import { InvitePanel } from '@/features/invites/invite-panel';
import { ReportPanel } from '@/features/reports/report-panel';
import { can, getOrgContext, isUuid, num, publicSettings } from '@/lib/org';

const TABS = ['overview', 'controls', 'invites', 'pin', 'reports'] as const;

export async function generateMetadata({ params }: { params: Promise<{ org: string; id: string }> }): Promise<Metadata> {
  const { org, id } = await params;
  if (!isUuid(id)) return {};
  const { core } = await getOrgContext(org);
  const { data } = await core.from('campaigns').select('title').eq('id', id).maybeSingle();
  return { title: data?.title ?? (await getTranslations('brand.dashboard'))('title') };
}

export default async function CampaignDashboardPage({
  params,
  searchParams,
}: {
  params: Promise<{ org: string; id: string }>;
  searchParams: Promise<{ tab?: string }>;
}) {
  const [{ org: orgId, id }, sp] = await Promise.all([params, searchParams]);
  if (!isUuid(id)) notFound();
  const { core, role } = await getOrgContext(orgId);
  const { data: c } = await core
    .from('campaigns')
    .select('id, org_id, title, status, visibility, is_template, submit_deadline, start_at, pinned_until, review_mode, service_mode')
    .eq('id', id)
    .maybeSingle();
  if (!c?.id || c.org_id !== orgId) notFound();

  const now = new Date().toISOString();
  const invite = c.visibility === 'invite';
  const [t, locale, statsRes, { data: alerts }, { data: rules }, invites, { data: links }, settings] = await Promise.all([
    getTranslations('brand'),
    getLocale(),
    core.rpc('campaign_stats', { p_campaign: id }),
    core.from('budget_alerts').select('kind, created_at').eq('campaign_id', id).order('created_at'),
    core.from('rate_rules').select('id, lineage_id, kind, platform, pool_id, params, effective_to').eq('campaign_id', id).or(`effective_to.is.null,effective_to.gt.${now}`).order('effective_from'),
    invite ? core.from('campaign_invites').select('user_id, created_at').eq('campaign_id', id).order('created_at', { ascending: false }).limit(500) : null,
    core.from('report_links').select('id, created_at, expires_at, revoked_at').eq('campaign_id', id).order('created_at', { ascending: false }),
    publicSettings(core, ['public.billing.pin_price_per_week_idr']),
  ]);
  const stats = parseStats(statsRes.data);
  const loc = locale === 'en' ? 'en' : 'id';
  const status = c.status ?? 'draft';
  const base = `/${orgId}/campaigns/${id}`;
  const poolById = new Map(stats.pools.map((p) => [p.poolId, p]));
  const controlRules: ControlRule[] = (rules ?? []).flatMap((r) => {
    const pool = r.pool_id ? poolById.get(r.pool_id) : undefined;
    return r.id && r.kind
      ? [{ id: r.id, lineage: r.lineage_id ?? r.id, kind: r.kind, platform: r.platform, code: pool?.code ?? '', unitLabel: pool?.code === 'IDR' ? 'Rp' : (pool?.unitLabel ?? ''), params: (r.params ?? {}) as Record<string, unknown> }]
      : [];
  });
  const inviteRows = invites?.data ?? [];
  const inviteIds = inviteRows.map((i) => i.user_id).filter((x): x is string => !!x);
  const { data: profiles } = inviteIds.length ? await core.from('profiles').select('id, username').in('id', inviteIds) : { data: [] };
  const usernames = new Map((profiles ?? []).map((p) => [p.id, p.username ?? '']));
  const tab = TABS.includes(sp.tab as (typeof TABS)[number]) && (sp.tab !== 'invites' || invite) ? sp.tab! : 'overview';
  const edit = can(role, 'edit');
  const running = ['scheduled', 'live', 'paused'].includes(status);
  const pinned = c.pinned_until && c.pinned_until > now;

  return (
    <>
      <PageHeader
        breadcrumb={<Breadcrumb linkAs={Link} items={[{ label: t('nav.campaigns'), href: `/${orgId}/campaigns` }, { label: c.title ?? '' }]} />}
        title={<span className="break-words">{c.title || t('campaigns.untitled')}</span>}
        meta={
          <>
            <StatusBadge kind="campaign" status={status} label={t(`campaignStatus.${status}`)} />
            {invite ? <Badge tone="outline" icon="lock">{t('campaigns.private')}</Badge> : null}
            {pinned ? <Badge tone="primary" icon="push_pin">{t('campaigns.pinned')}</Badge> : null}
          </>
        }
        description={
          c.submit_deadline
            ? t('dashboard.schedule', {
                start: c.start_at ? formatDateTime(c.start_at, loc) : '—',
                deadline: formatDateTime(c.submit_deadline, loc),
              })
            : undefined
        }
        actions={
          edit ? (
            <Button href={`/${orgId}/campaigns/new?campaign=${id}`} linkAs={Link} variant="secondary" iconLeft="edit">
              {EDITABLE_STATUSES.includes(status) ? t('campaigns.edit') : t('campaigns.editFaq')}
            </Button>
          ) : null
        }
      />
      {c.is_template ? <Alert tone="info" className="mb-4">{t('dashboard.isTemplate')}</Alert> : null}
      {status === 'in_review' ? <Alert tone="info" className="mb-4">{t('dashboard.inReview')}</Alert> : null}
      {statsRes.error ? <Alert tone="danger" className="mb-4">{t('dashboard.statsError')}</Alert> : null}

      <Tabs defaultValue={tab}>
        <TabsList variant="underline" aria-label={t('dashboard.tabsLabel')}>
          <TabsTrigger value="overview" icon="monitoring">{t('dashboard.tabOverview')}</TabsTrigger>
          <TabsTrigger value="controls" icon="tune">{t('dashboard.tabControls')}</TabsTrigger>
          {invite ? <TabsTrigger value="invites" icon="person_add" count={inviteRows.length}>{t('dashboard.tabInvites')}</TabsTrigger> : null}
          <TabsTrigger value="pin" icon="push_pin">{t('dashboard.tabPin')}</TabsTrigger>
          <TabsTrigger value="reports" icon="description">{t('dashboard.tabReports')}</TabsTrigger>
        </TabsList>
        <TabsContent value="overview">
          <Overview stats={stats} status={status} alerts={(alerts ?? []).flatMap((a) => (a.kind && a.created_at ? [{ kind: a.kind, created_at: a.created_at }] : []))} inviteTab={invite} base={base} />
        </TabsContent>
        <TabsContent value="controls">
          <ControlPanel
            orgId={orgId}
            campaignId={id}
            title={c.title ?? ''}
            status={status}
            submitDeadline={c.submit_deadline}
            rules={controlRules}
            pools={stats.pools.map((p) => ({ poolId: p.poolId, code: p.code, unitLabel: p.unitLabel, decimals: p.decimals }))}
            canControl={edit && !c.is_template}
            canFund={can(role, 'fund') && !c.is_template}
            canBilling={can(role, 'billing')}
          />
        </TabsContent>
        {invite ? (
          <TabsContent value="invites">
            <InvitePanel
              orgId={orgId}
              campaignId={id}
              canInvite={edit && !['cancelled', 'rejected', 'settling', 'settled'].includes(status)}
              invites={inviteRows.flatMap((i) => (i.user_id ? [{ userId: i.user_id, username: usernames.get(i.user_id) ?? '', at: i.created_at ?? '' }] : []))}
            />
          </TabsContent>
        ) : null}
        <TabsContent value="pin">
          <PinPanel
            orgId={orgId}
            campaignId={id}
            pricePerWeek={num(settings['public.billing.pin_price_per_week_idr'], 500_000)}
            pinnedUntil={c.pinned_until}
            canBuy={can(role, 'fund')}
            canBilling={can(role, 'billing')}
            running={running && !c.is_template}
          />
        </TabsContent>
        <TabsContent value="reports">
          <ReportPanel
            orgId={orgId}
            campaignId={id}
            csvHref={`${base}/report.csv`}
            canManage={edit}
            links={(links ?? []).flatMap((l) => (l.id ? [{ id: l.id, createdAt: l.created_at ?? '', expiresAt: l.expires_at, revokedAt: l.revoked_at }] : []))}
          />
        </TabsContent>
      </Tabs>
    </>
  );
}
