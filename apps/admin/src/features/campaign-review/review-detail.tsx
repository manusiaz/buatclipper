import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { coreServer } from '@clipper/auth/server';
import {
  Badge, Button, Card, formatDateTime, formatIDR, formatNumber, Icon, PlatformChip, StatusBadge,
  type Platform, type UiLocale,
} from '@clipper/ui';
import { must, rows } from '@/lib/data';
import { ActionDialog } from '@/features/shared/action-dialog';
import { Brief } from '@/features/shared/brief';
import { reviewCampaign } from './actions';
import { assetHrefs, fileName, type AssetRow } from './assets';
import { amount, ruleParams, type PoolJson, type RuleJson } from './format';

export const CAMPAIGN_REJECT_REASONS = ['asset_rights', 'brief_unsafe', 'misleading', 'incomplete', 'budget', 'other'] as const;

interface Detail {
  campaign: Record<string, unknown> & { id: string; org_id: string; title: string; status: string; platforms: Platform[] };
  rules: RuleJson[];
  pools: PoolJson[];
  budget_idr: number | string;
  assets: (AssetRow & { bucket: string | null })[];
}

const list = (v: unknown) => (Array.isArray(v) ? (v as string[]) : []);

/** F-A02 detail campaign in_review: brief, aset (signed URL), budget & rate, status invoice → approve/reject. */
export async function ReviewDetail({ id, loc, canSeeInvoices }: { id: string; loc: UiLocale; canSeeInvoices: boolean }) {
  const [t, tc, db] = await Promise.all([getTranslations('admin'), getTranslations('common'), coreServer('admin')]);
  const d = must(await db.rpc('campaign_detail', { p_campaign: id })) as unknown as Detail;
  const c = d.campaign;
  const [org, invoices, hrefs] = await Promise.all([
    db.from('organizations').select('id, name, status, org_type').eq('id', c.org_id).maybeSingle(),
    canSeeInvoices
      ? db.from('invoices').select('id, number, status, total, kind').eq('campaign_id', id).eq('kind', 'campaign').neq('status', 'void')
      : Promise.resolve({ data: [], error: null }),
    assetHrefs(db, d.assets),
  ]);
  const o = must(org);
  const inv = rows(invoices);
  const reasonOptions = CAMPAIGN_REJECT_REASONS.map((r) => ({ value: r, label: t(`campaigns.reasons.${r}`) }));
  const when = (v: unknown) => (typeof v === 'string' ? formatDateTime(v, loc) : '—');
  const facts: [string, string][] = [
    [t('campaigns.f.type'), String(c.type ?? '—')],
    [t('campaigns.f.start'), when(c.start_at)],
    [t('campaigns.f.deadline'), when(c.submit_deadline)],
    [t('campaigns.f.window'), t('campaigns.days', { n: Number(c.view_window_days ?? 0) })],
    [t('campaigns.f.review'), t(`campaigns.reviewMode.${c.review_mode}`)],
    [t('campaigns.f.visibility'), t(`campaigns.visibility.${c.visibility}`)],
    [t('campaigns.f.minFollowers'), formatNumber(Number(c.min_followers ?? 0), loc)],
    [t('campaigns.f.minTrust'), String(c.min_trust_score ?? 0)],
    [t('campaigns.f.kyc'), c.kyc_required ? t('common.yes') : t('common.no')],
    [t('campaigns.f.quota'), c.clipper_quota == null ? '∞' : formatNumber(Number(c.clipper_quota), loc)],
    [t('campaigns.f.maxClips'), String(c.max_clips_per_clipper ?? '—')],
    [t('campaigns.f.minViews'), formatNumber(Number(c.min_views ?? 0), loc)],
  ];
  const tags = [...list(c.required_hashtags).map((h) => `#${h}`), ...list(c.required_mentions).map((m) => `@${m}`)];

  return (
    <Card padding="none" className="mb-6">
      <div className="flex flex-col gap-4 border-b border-border p-5 md:flex-row md:items-start md:justify-between">
        <div className="flex min-w-0 flex-col gap-2">
          <Link href="/campaigns" className="inline-flex items-center gap-1 text-body-s font-semibold text-link focus-ring">
            <Icon name="arrow_back" size={16} />
            {t('campaigns.backToQueue')}
          </Link>
          <h2 className="text-h4 break-words text-ink">{c.title}</h2>
          <div className="flex flex-wrap items-center gap-2 text-body-s text-muted">
            <span className="font-semibold text-ink">{o?.name ?? '—'}</span>
            {o?.status ? <StatusBadge kind="org" status={o.status as 'verified'} label={t(`status.org.${o.status}`)} /> : null}
            <Badge tone="outline">{t(`campaigns.serviceMode.${c.service_mode}`)}</Badge>
            {c.platforms.map((p) => (
              <PlatformChip key={p} platform={p} />
            ))}
          </div>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          <ActionDialog
            trigger={{ label: t('campaigns.reject'), variant: 'danger', icon: 'block', size: 'md' }}
            title={t('campaigns.rejectTitle')}
            description={c.title}
            tone="danger"
            submitLabel={t('campaigns.reject')}
            success={t('campaigns.rejected')}
            action={reviewCampaign.bind(null, id, 'reject')}
            fields={[
              { kind: 'select', name: 'reason', label: t('campaigns.reason'), options: reasonOptions, required: true },
              { kind: 'textarea', name: 'message', label: t('campaigns.messageToBrand'), required: true, maxLength: 1000 },
              { kind: 'textarea', name: 'note', label: t('form.internalNote'), maxLength: 1000 },
            ]}
          />
          <ActionDialog
            trigger={{ label: t('campaigns.approve'), variant: 'primary', icon: 'check_circle', size: 'md' }}
            title={t('campaigns.approveTitle')}
            description={t('campaigns.approveBody')}
            submitLabel={t('campaigns.approve')}
            success={t('campaigns.approved')}
            action={reviewCampaign.bind(null, id, 'approve')}
            fields={[
              { kind: 'textarea', name: 'message', label: t('campaigns.messageToBrand'), maxLength: 1000 },
              { kind: 'textarea', name: 'note', label: t('form.internalNote'), maxLength: 1000 },
            ]}
          />
        </div>
      </div>

      <div className="grid grid-cols-1 gap-6 p-5 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="flex min-w-0 flex-col gap-5">
          <section className="flex flex-col gap-2">
            <h3 className="text-h6 text-ink">{t('campaigns.brief')}</h3>
            <Brief text={c.brief as string} />
          </section>
          {tags.length || list(c.required_links).length ? (
            <section className="flex flex-col gap-2">
              <h3 className="text-label text-ink">{t('campaigns.requirements')}</h3>
              <div className="flex flex-wrap gap-1.5">
                {tags.map((x) => (
                  <Badge key={x} tone="neutral">{x}</Badge>
                ))}
                {list(c.required_links).map((l) => (
                  <Badge key={l} tone="outline" className="max-w-full truncate">{l}</Badge>
                ))}
              </div>
            </section>
          ) : null}
          {(['dos', 'donts'] as const).map((k) =>
            list(c[k]).length ? (
              <section key={k} className="flex flex-col gap-1.5">
                <h3 className="text-label text-ink">{t(`campaigns.${k}`)}</h3>
                <ul className="list-disc pl-5 text-body-s text-text-2">
                  {list(c[k]).map((x, i) => (
                    <li key={i}>{x}</li>
                  ))}
                </ul>
              </section>
            ) : null,
          )}
          <section className="flex flex-col gap-2">
            <h3 className="text-label text-ink">{t('campaigns.assets')}</h3>
            {d.assets.length === 0 ? (
              <p className="text-body-s text-muted">{t('campaigns.noAssets')}</p>
            ) : (
              <ul className="flex flex-col gap-1.5">
                {d.assets.map((a) => (
                  <li key={a.id} className="flex items-center gap-2 text-body-s">
                    <Icon name={a.kind === 'link' ? 'link' : a.kind === 'cover' ? 'image' : 'description'} size={18} className="text-muted" />
                    {hrefs.get(a.id!) ? (
                      <a href={hrefs.get(a.id!)} target="_blank" rel="noopener noreferrer" className="min-w-0 truncate font-semibold text-link hover:underline">
                        {fileName(a)}
                      </a>
                    ) : (
                      <span className="min-w-0 truncate">{fileName(a)}</span>
                    )}
                    <Badge tone={a.audience === 'internal' ? 'warn' : 'neutral'} size="sm">{t(`campaigns.audience.${a.audience}`)}</Badge>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>

        <div className="flex min-w-0 flex-col gap-5">
          <Card variant="tint" padding="md" className="flex flex-col gap-2">
            <h3 className="text-label text-ink">{t('campaigns.invoice')}</h3>
            {!canSeeInvoices ? (
              <p className="text-body-s text-muted">{t('campaigns.invoiceHidden')}</p>
            ) : inv.length === 0 ? (
              <p className="text-body-s text-muted">{t('campaigns.invoiceNone')}</p>
            ) : (
              inv.map((i) => (
                <div key={i.id} className="flex flex-wrap items-center justify-between gap-2 text-body-s">
                  <span className="font-mono text-caption">{i.number}</span>
                  <span className="tnum font-semibold">{formatIDR(Number(i.total), { locale: loc })}</span>
                  <Badge tone={i.status === 'paid' ? 'success' : 'warn'}>{t(`finance.invoiceStatus.${i.status}`)}</Badge>
                </div>
              ))
            )}
          </Card>
          <section className="flex flex-col gap-2">
            <h3 className="text-label text-ink">
              {t('campaigns.budget')} · {formatIDR(Number(d.budget_idr), { locale: loc })}
            </h3>
            <ul className="flex flex-col gap-1 text-body-s">
              {d.pools.map((p) => (
                <li key={p.pool_id} className="flex justify-between gap-3">
                  <span className="font-semibold text-ink">{p.code}</span>
                  <span className="tnum text-text-2">
                    {amount(p.total, p.code, p.unit_label, loc)}
                    {p.max_per_clip != null ? ` · ${t('campaigns.maxPerClip', { v: amount(p.max_per_clip, p.code, p.unit_label, loc) })}` : ''}
                  </span>
                </li>
              ))}
            </ul>
            <ul className="flex flex-col gap-1 text-body-s">
              {d.rules.map((r, i) => (
                <li key={r.rule_id ?? i} className="flex flex-wrap justify-between gap-x-3 text-text-2">
                  <span>
                    {t(`campaigns.ruleKinds.${r.kind}`)} · {r.platform ? tc(`platforms.${r.platform}`) : t('campaigns.allPlatforms')}
                  </span>
                  <span className="tnum">{ruleParams(r, loc)}</span>
                </li>
              ))}
            </ul>
          </section>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-body-s">
            {facts.map(([k, v]) => (
              <div key={k} className="flex flex-col">
                <dt className="text-caption text-muted">{k}</dt>
                <dd className="font-semibold text-ink">{v}</dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </Card>
  );
}

/** Tombol buka di builder untuk draft managed (A7.1). */
export function TakeButton({ id, label }: { id: string; label: string }) {
  return (
    <Button href={`/campaigns/new?campaign=${id}`} linkAs={Link} size="sm" iconRight="arrow_forward">
      {label}
    </Button>
  );
}

