import { randomUUID } from 'node:crypto';
import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { draftFromDetail, type CampaignDraft } from '@clipper/campaign-builder';
import { Alert, Card, EmptyState } from '@clipper/ui';
import { campaignUploadUrl, saveCampaign } from '@/features/campaigns/actions';
import { BuilderHost } from '@/features/campaigns/builder-host';
import { builderContext } from '@/features/campaigns/builder-context';
import { can, getOrgContext, isUuid } from '@/lib/org';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.builder'))('title') };
}

export default async function CampaignBuilderPage({
  params,
  searchParams,
}: {
  params: Promise<{ org: string }>;
  searchParams: Promise<{ campaign?: string }>;
}) {
  const [{ org: orgId }, { campaign }] = await Promise.all([params, searchParams]);
  const ctx = await getOrgContext(orgId);
  const t = await getTranslations('brand');
  const base = `/${orgId}/campaigns`;
  if (!can(ctx.role, 'edit')) {
    return (
      <Card padding="lg">
        <EmptyState
          icon="lock"
          title={t('builder.readOnlyTitle')}
          body={t('builder.readOnlyBody')}
          action={{ label: t('builder.back'), href: isUuid(campaign) ? `${base}/${campaign}` : base, linkAs: Link }}
        />
      </Card>
    );
  }

  let initial: CampaignDraft | null = null;
  let rejection: { reason: string; message: string } | null = null;
  if (campaign) {
    if (!isUuid(campaign)) notFound();
    const { data: detail, error } = await ctx.core.rpc('campaign_detail', { p_campaign: campaign });
    if (error || !detail) notFound();
    initial = draftFromDetail(detail);
    if (initial.org_id !== orgId) notFound();
    if (initial.status === 'rejected') {
      const { data: d } = await ctx.core
        .from('review_decisions')
        .select('reason_code, message')
        .eq('target_type', 'campaign')
        .eq('target_id', campaign)
        .eq('decision', 'reject')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      rejection = { reason: d?.reason_code ?? '', message: d?.message ?? '' };
    }
  }

  return (
    <div className="flex flex-col gap-4">
      {rejection ? (
        <Alert tone="danger" title={t('builder.rejectedTitle')}>
          {[rejection.reason, rejection.message].filter(Boolean).join(' — ') || t('builder.rejectedBody')}
        </Alert>
      ) : null}
      <BuilderHost
        orgId={orgId}
        renderId={randomUUID()}
        context={await builderContext(ctx)}
        initial={initial}
        save={saveCampaign.bind(null, orgId)}
        uploadUrl={campaignUploadUrl.bind(null, orgId)}
      />
    </div>
  );
}
