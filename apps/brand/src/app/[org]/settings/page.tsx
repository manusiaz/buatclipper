import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { hosts, kycUrl } from '@clipper/auth';
import { Alert, Card, CardContent, CardHeader, CardTitle, PageHeader, StatusBadge, formatDate, formatDateTime } from '@clipper/ui';
import { AgencyPanel, type AgencyLink } from '@/features/org/agency-panel';
import { EditOrgDialog } from '@/features/org/edit-org-dialog';
import { getOrgContext } from '@/lib/org';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('settings') };
}

const linkState = (l: { approved_at: string | null; revoked_at: string | null }): AgencyLink['state'] =>
  l.revoked_at ? 'revoked' : l.approved_at ? 'approved' : 'pending';

export default async function SettingsPage({ params }: { params: Promise<{ org: string }> }) {
  const { org: orgId } = await params;
  const { core, brand, org, role, direct, claims } = await getOrgContext(orgId);
  const [t, locale, { data: links }, { data: decision }, { data: requests }, { data: orgs }] = await Promise.all([
    getTranslations('brand'),
    getLocale(),
    brand.from('org_links').select('agency_org_id, client_org_id, approved_at, revoked_at, created_at').or(`agency_org_id.eq.${orgId},client_org_id.eq.${orgId}`),
    core.from('review_decisions').select('decision, reason_code, message, created_at').eq('target_type', 'org').eq('target_id', orgId).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    // Nama agency peminta tidak terbuka lewat RLS organizations untuk klien; payload notifikasi agency.link_requested membawanya.
    core.from('notifications').select('payload').eq('user_id', claims.sub).eq('event', 'agency.link_requested').order('created_at', { ascending: false }).limit(50),
    brand.from('organizations').select('id, name'),
  ]);
  const loc = locale === 'en' ? 'en' : 'id';
  const names = new Map<string, string>((orgs ?? []).flatMap((o) => (o.id && o.name ? [[o.id, o.name] as [string, string]] : [])));
  for (const n of requests ?? []) {
    const p = (n.payload ?? {}) as { agency_org_id?: string; agency_org_name?: string };
    if (p.agency_org_id && p.agency_org_name && !names.has(p.agency_org_id)) names.set(p.agency_org_id, p.agency_org_name);
  }
  const all = (links ?? []).flatMap((l) =>
    l.agency_org_id && l.client_org_id
      ? [{ agencyId: l.agency_org_id, clientId: l.client_org_id, state: linkState(l), at: l.approved_at ?? l.created_at ?? '' }]
      : [],
  );
  const asAgency = all.filter((l) => l.agencyId === orgId).map((l) => ({ ...l, otherName: names.get(l.clientId) ?? '' }));
  const asClient = all.filter((l) => l.clientId === orgId).map((l) => ({ ...l, otherName: names.get(l.agencyId) ?? '' }));
  const ownerDirect = direct && role === 'brand_owner';
  const rejected = org.status === 'pending_verification' && decision?.decision === 'reject';
  // update_org setelah penolakan = diajukan ulang (B1.5); admin melihat "Diubah brand" di detail org.
  const resubmitted = rejected && !!org.updated_at && !!decision.created_at && new Date(org.updated_at) > new Date(decision.created_at);
  const rows: [string, string][] = [
    [t('settings.name'), org.name],
    [t('settings.type'), t(`settings.types.${org.org_type ?? 'badan'}`)],
    ...(org.org_type === 'badan'
      ? ([
          [t('settings.legalName'), org.legal_name ?? '—'],
          [t('settings.npwp'), org.npwp ?? '—'],
          [t('settings.address'), org.address ?? '—'],
        ] as [string, string][])
      : []),
    [t('settings.agency'), org.is_agency ? t('settings.yes') : t('settings.no')],
    [t('settings.created'), org.created_at ? formatDate(org.created_at, loc) : '—'],
    ...(org.verified_at ? ([[t('settings.verifiedAt'), formatDateTime(org.verified_at, loc)]] as [string, string][]) : []),
  ];

  return (
    <>
      <PageHeader title={t('settings.title')} description={t('settings.description')} />
      <div className="flex flex-col gap-5">
        {resubmitted ? (
          <Alert tone="info" title={t('settings.resubmittedTitle')}>
            {t('settings.resubmittedBody', { date: formatDateTime(org.updated_at!, loc) })}
          </Alert>
        ) : rejected ? (
          <Alert tone="danger" title={t('settings.rejectedTitle')}>
            {[decision.reason_code, decision.message].filter(Boolean).join(' — ')}
            {ownerDirect ? <span className="mt-1 block">{t('settings.rejectedFix')}</span> : null}
          </Alert>
        ) : null}
        <Card>
          <CardHeader actions={<StatusBadge kind="org" status={org.status ?? ''} label={t(`orgStatus.${org.status ?? 'pending_verification'}`)} />}>
            <CardTitle>{t('settings.profile')}</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            <dl className="grid grid-cols-1 gap-x-6 gap-y-3 text-body-s sm:grid-cols-2 [&>*]:min-w-0">
              {rows.map(([k, v]) => (
                <div key={k} className="min-w-0">
                  <dt className="text-muted">{k}</dt>
                  <dd className="break-words font-semibold text-ink">{v}</dd>
                </div>
              ))}
            </dl>
            {org.org_type === 'perorangan' ? (
              <Alert tone="info" action={ownerDirect && claims.kyc !== 'approved' ? { label: t('banner.kycAction'), href: kycUrl(`${hosts.brand}/${orgId}/settings`) } : undefined}>
                {t('settings.peroranganNote')}
              </Alert>
            ) : null}
            {ownerDirect ? (
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <p className="text-caption text-muted">{org.org_type === 'badan' ? t('settings.editNote') : null}</p>
                <EditOrgDialog
                  orgId={orgId}
                  badan={org.org_type === 'badan'}
                  verified={org.status === 'verified'}
                  initial={{ name: org.name, legal_name: org.legal_name ?? '', npwp: org.npwp ?? '', address: org.address ?? '' }}
                />
              </div>
            ) : null}
          </CardContent>
        </Card>
        <section aria-labelledby="agency" className="flex flex-col gap-3">
          <h2 id="agency" className="text-h5 text-ink">{t('agency.title')}</h2>
          <AgencyPanel
            orgId={orgId}
            isAgency={!!org.is_agency}
            canRequest={direct && (role === 'brand_owner' || role === 'brand_manager')}
            canRevokeAsAgency={ownerDirect}
            isClientOwner={ownerDirect}
            asAgency={asAgency}
            asClient={asClient}
          />
        </section>
      </div>
    </>
  );
}
