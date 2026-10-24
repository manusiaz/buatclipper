import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { draftFromDetail, type BuilderContext, type CampaignDraft, type Platform } from '@clipper/campaign-builder';
import { Alert, Card, EmptyState, Icon, PageHeader, SearchInput, StatusBadge, type UiLocale } from '@clipper/ui';
import { isUuid, likeTerm, must, param, rows, type SearchParams } from '@/lib/data';
import { AdminBuilder } from '@/features/builder/admin-builder';
import { SidePanel } from '@/features/builder/side-panel';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.builder') };
}

const FLAGS_DEFAULT: Record<Platform, boolean> = { tiktok: true, instagram: true, youtube: true, threads: false, facebook: false, x: false };

// F-A03 / A7.2: builder bersama (packages/campaign-builder) mode admin. ?campaign= draft yang ada (paket managed), ?org= draft
// baru atas nama org, tanpa keduanya = pilih org.
export default async function AdminBuilderPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  await requireAdmin(...rolesFor('builder'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const campaignId = param(sp, 'campaign');
  let orgId = param(sp, 'org');
  let initial: CampaignDraft | null = null;
  let detail: Record<string, unknown> | null = null;

  if (isUuid(campaignId)) {
    detail = must(await db.rpc('campaign_detail', { p_campaign: campaignId })) as Record<string, unknown>;
    initial = draftFromDetail(detail);
    orgId = initial.org_id;
  }
  if (!isUuid(orgId)) return <OrgPicker q={param(sp, 'q')} />;

  const [orgRes, campRes, catRes, rtRes, setRes] = await Promise.all([
    db.from('organizations').select('id, name, status, fee_rule_id').eq('id', orgId).maybeSingle(),
    initial?.id ? db.from('campaigns').select('fee_rule_id').eq('id', initial.id).maybeSingle() : Promise.resolve({ data: null, error: null }),
    db.from('categories').select('id, name_id, name_en').eq('active', true).order('sort'),
    db.from('reward_types').select('id, code, name, unit_label, kind, idr_value_per_unit, decimals, owner_org_id, fulfillment')
      .or(`owner_org_id.is.null,owner_org_id.eq.${orgId}`).order('code'),
    db.from('settings').select('key, value').in('key', ['public.flags.platforms', 'public.billing.tax_pct', 'public.billing.managed_service_idr']),
  ]);
  const org = must(orgRes);
  if (!org?.id) return <EmptyState icon="storefront" tone="neutral" title={t('builder.orgMissing')} action={{ label: t('builder.pickOrg'), href: '/campaigns/new', linkAs: Link }} />;
  const cfg = new Map(rows(setRes).map((s) => [s.key, s.value]));
  // Fee efektif campaign → org → global (finance.effective_fee_rule); aturan org + global jadi pilihan override.
  const campaignRule = must(campRes)?.fee_rule_id ?? null;
  const feeRows = rows(await db.from('fee_rules').select('id, scope, mgmt_fee_pct, admin_fee_pct')
    .or(['scope.eq.global', ...[org.fee_rule_id, campaignRule].filter(Boolean).map((r) => `id.eq.${r}`)].join(',')));
  const pct = (r?: (typeof feeRows)[number]) => ({ mgmt_fee_pct: Number(r?.mgmt_fee_pct ?? 0), admin_fee_pct: Number(r?.admin_fee_pct ?? 0) });
  const byId = (id: string | null) => feeRows.find((r) => id && r.id === id);
  const global = feeRows.find((r) => r.scope === 'global');
  const fee = pct(byId(campaignRule) ?? byId(org.fee_rule_id) ?? global);

  const context: BuilderContext = {
    mode: 'admin',
    org: { id: org.id, name: org.name ?? '', status: org.status ?? 'pending_verification' },
    categories: rows(catRes).map((c) => ({ id: c.id!, name_id: c.name_id ?? '', name_en: c.name_en ?? '' })),
    rewardTypes: rows(rtRes)
      .filter((r) => r.fulfillment !== null)
      .map((r) => ({
        id: r.id!, code: r.code ?? '', name: r.name ?? '', unit_label: r.unit_label ?? '', kind: r.kind ?? '',
        idr_value_per_unit: Number(r.idr_value_per_unit ?? 0), decimals: Number(r.decimals ?? 0), owner_org_id: r.owner_org_id,
      })),
    platforms: { ...FLAGS_DEFAULT, ...((cfg.get('public.flags.platforms') as Record<Platform, boolean> | undefined) ?? {}) },
    fee,
    taxPct: Number(cfg.get('public.billing.tax_pct') ?? 11),
    managedServiceIdr: Number(cfg.get('public.billing.managed_service_idr') ?? 2_500_000),
    feeRules: [byId(org.fee_rule_id), global].filter((r) => !!r).map((r) => ({ id: r!.id!, scope: r!.scope!, ...pct(r) })),
  };
  const managed = initial?.service_mode === 'managed';

  return (
    <>
      {org.status === 'suspended' ? (
        <Alert tone="danger" className="mb-4">
          {t('builder.orgSuspended')}
        </Alert>
      ) : null}
      <AdminBuilder
        context={context}
        initial={initial}
        sidePanel={managed && detail ? <SidePanel detail={detail} loc={locale as UiLocale} /> : undefined}
      />
    </>
  );
}

async function OrgPicker({ q }: { q: string }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  let query = db.from('organizations').select('id, name, status, org_type, created_at').order('created_at', { ascending: false }).limit(30);
  if (q) query = query.ilike('name', likeTerm(q));
  const orgs = rows(await query);
  return (
    <>
      <PageHeader title={t('builder.title')} description={t('builder.pickOrgBody')} />
      <form className="mb-4 max-w-md" action="/campaigns/new">
        <SearchInput name="q" defaultValue={q} placeholder={t('builder.searchOrg')} aria-label={t('builder.searchOrg')} />
      </form>
      {orgs.length === 0 ? (
        <EmptyState icon="storefront" tone="neutral" title={t('builder.noOrg')} />
      ) : (
        <Card padding="none">
          <ul className="divide-y divide-border">
            {orgs.map((o) => (
              <li key={o.id}>
                <Link href={`/campaigns/new?org=${o.id}`} className="flex min-h-14 items-center gap-3 px-4 py-3 hover:bg-subtle focus-ring">
                  <Icon name="storefront" size={20} className="text-muted" />
                  <span className="min-w-0 flex-1 truncate font-semibold text-ink">{o.name}</span>
                  <span className="hidden text-caption text-muted sm:inline">{t(`users.orgType.${o.org_type}`)}</span>
                  <StatusBadge kind="org" status={o.status!} label={t(`status.org.${o.status}`)} />
                  <Icon name="chevron_right" size={18} className="text-faint" />
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      )}
      <p className="mt-4 text-body-s text-muted">
        {t('builder.orManaged')}{' '}
        <Link href="/campaigns?tab=managed" className="font-semibold text-link hover:underline">
          {t('campaigns.tabManaged')}
        </Link>
      </p>
    </>
  );
}
