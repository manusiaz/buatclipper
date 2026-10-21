import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import {
  Avatar,
  Badge,
  Button,
  Card,
  CardHeader,
  CardTitle,
  CopyField,
  EmbedFrame,
  Icon,
  PlatformChip,
  ProgressBar,
  StatusBadge,
  earningFor,
  formatCompact,
  formatDateTime,
  formatIDR,
  formatNumber,
  type Platform,
} from '@clipper/ui';
import { Brief } from '@/features/campaigns/brief';
import { categoryNames } from '@/features/campaigns/cards';
import { parseDetail } from '@clipper/clipper-lib/detail';
import { detailText } from '@clipper/clipper-lib/detail-text';
import { DetailCta } from '@/features/claim/detail-cta';
import { budgetUsedRatio, cardRates, httpsUrl, isPlatform, isUuid, maxViews } from '@clipper/clipper-lib/pure';
import { core, errorText, myClipTerms, publicUrl, uiLocale } from '@/features/lib/server';

export const metadata: Metadata = { title: 'Detail campaign' };

type Props = { params: Promise<{ id: string }>; searchParams: Promise<{ submit?: string; url?: string }> };

// F-C04–C06 / C1.6, C1.8: brief lengkap, rate & cap per platform, timeline absolut (WIB), claim, submit.
export default async function CampaignDetailPage({ params, searchParams }: Props) {
  const { claims } = await requireClipper();
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!isUuid(id)) notFound();
  const db = await core();
  const { data, error } = await db.rpc('campaign_detail', { p_campaign: id });
  if (error) {
    if (error.message.startsWith('not_found')) notFound();
    throw new Error(error.message);
  }
  const d = parseDetail(data);
  const c = d.campaign;
  const platforms = c.platforms.filter(isPlatform) as Platform[];
  const files = d.assets.filter((a) => a.kind !== 'cover');
  const privatePaths = files.filter((a) => a.storage_path && a.bucket === 'campaign-assets').map((a) => a.storage_path!);

  const [t, locale, categories, social, signed, terms] = await Promise.all([
    getTranslations('clipper'),
    uiLocale(),
    categoryNames(),
    db
      .from('social_accounts')
      .select('id,platform,handle,status')
      .eq('user_id', claims.sub)
      .in('platform', platforms)
      .neq('status', 'disconnected'),
    privatePaths.length ? db.storage.from('campaign-assets').createSignedUrls(privatePaths, 3600) : Promise.resolve({ data: [] }),
    myClipTerms(),
  ]);
  const signedUrl = new Map((signed.data ?? []).map((s) => [s.path, s.signedUrl]));
  const reasonText =
    d.cta_state === 'not_eligible' && d.cta_reason
      ? await errorText(`not_eligible:${d.cta_reason}`)
      : d.cta_state && ['slots_full', 'budget_exhausted', 'deadline_passed'].includes(d.cta_state)
        ? await errorText(d.cta_state)
        : null;

  const cover = d.assets.find((a) => a.kind === 'cover' && a.storage_path);
  const coverSrc = publicUrl('campaign-covers', cover?.storage_path);
  const idr = new Map(d.pools.map((p) => [p.reward_type_id, p.idr_value_per_unit]));
  const top = cardRates(d.rules, platforms, idr).sort((a, b) => b.ratePer1k - a.ratePer1k)[0];
  const views = maxViews(d.est_remaining_views);
  const used = budgetUsedRatio(d.budget_idr, d.remaining_idr);
  const when = (v: string | null) => (v ? `${formatDateTime(v, locale, { dateStyle: 'long', timeStyle: 'short' })} WIB` : '—');
  const text = detailText(d, platforms, terms, locale, (k, v) => t(k as Parameters<typeof t>[0], v as never));
  const { capText, describe, rateGroups, tags, requirements } = text;

  return (
    <article className="flex flex-col gap-4">
      <header className="flex flex-col gap-3">
        <div className="relative aspect-[16/9] overflow-hidden rounded-card bg-navy shadow-card">
          {coverSrc ? (
            <img src={coverSrc} alt="" className="size-full object-cover" />
          ) : (
            <div className="grid size-full place-items-center text-white/60">
              <Icon name="movie" size={48} />
            </div>
          )}
          <div className="absolute top-3 left-3 flex flex-wrap gap-1.5">
            <StatusBadge kind="campaign" status={c.status} label={t(`status.campaign.${c.status}`)} />
            {c.visibility !== 'public' ? <Badge tone="glass" icon="lock">{t(`detail.visibility.${c.visibility}`)}</Badge> : null}
          </div>
          <div className="absolute bottom-3 left-3 flex flex-wrap gap-1.5">
            {platforms.map((p) => (
              <PlatformChip key={p} platform={p} tone="glass" />
            ))}
          </div>
        </div>
        <div className="flex flex-col gap-1.5">
          {d.brand || c.category_id ? (
            <p className="flex min-w-0 items-center gap-1.5 text-caption text-muted">
              {d.brand ? (
                <>
                  <Avatar name={d.brand.name} size={20} shape="square" />
                  <span className="truncate font-semibold text-text-2">{d.brand.name}</span>
                  {d.brand.verified ? <Icon name="verified" size={14} filled className="shrink-0 text-primary" title={t('detail.verifiedBrand')} /> : null}
                </>
              ) : null}
              {d.brand && c.category_id ? <span aria-hidden>·</span> : null}
              {c.category_id ? <span className="truncate">{categories.get(c.category_id) ?? c.category_id}</span> : null}
            </p>
          ) : null}
          <h2 className="text-h4 text-ink [overflow-wrap:anywhere]">{c.title}</h2>
          {c.sponsored_label ? (
            <p className="flex items-center gap-1.5 text-caption font-semibold text-warn-fg">
              <Icon name="info" size={16} filled />
              {t('detail.sponsored')}
            </p>
          ) : null}
        </div>
      </header>

      <Card className="flex flex-col gap-3">
        <div className="flex flex-wrap items-end justify-between gap-x-3 gap-y-2">
          <div>
            <p className="text-caption text-muted">{t('detail.topRate')}</p>
            <p className="leading-none whitespace-nowrap">
              <span className="text-[26px] font-extrabold tracking-[-0.03em] tnum">{top ? formatIDR(top.ratePer1k, { locale }) : '—'}</span>
              <span className="ml-1 text-caption text-muted">/1K views</span>
            </p>
          </div>
          {top ? (
            <p className="rounded-chip bg-success-bg px-2.5 py-1.5 text-caption font-semibold whitespace-nowrap text-success-fg tnum">
              {t('detail.example', { views: formatNumber(10_000, locale), amount: formatIDR(earningFor(10_000, top.ratePer1k), { locale }) })}
            </p>
          ) : null}
        </div>
        {used !== undefined ? <ProgressBar value={used * 100} label={t('detail.budgetUsed')} tone="auto" /> : null}
        <div className="flex flex-wrap items-center justify-between gap-2 text-caption text-muted">
          <span className="font-semibold text-text-2 tnum">
            {views !== undefined ? t('detail.viewsLeft', { views: formatCompact(views, locale) }) : t('detail.noBudget')}
          </span>
          <span className="tnum">{t('detail.budgetLeft', { amount: formatIDR(d.remaining_idr, { locale, compact: true }) })}</span>
        </div>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t('detail.ratesTitle')}</CardTitle>
        </CardHeader>
        {rateGroups.length ? (
          <ul className="flex flex-col divide-y divide-border">
            {rateGroups.map((g) => (
              <li key={g.platform ?? 'all'} className="flex flex-col gap-1 py-2.5 first:pt-0 last:pb-0">
                <p className="text-label text-ink">{g.platform ? t(`platforms.${g.platform}`) : t('detail.allPlatforms')}</p>
                {g.rules.flatMap(describe).map((line, i) => (
                  <p key={i} className="text-body-s text-text-2 tnum">
                    {line}
                  </p>
                ))}
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-body-s text-muted">{t('detail.noRates')}</p>
        )}
        {d.clipper_fee_pct > 0 ? (
          <p className="text-body-s text-muted">{t('detail.clipperFee', { pct: formatNumber(d.clipper_fee_pct, locale) })}</p>
        ) : null}
        {d.pools.some((p) => p.max_per_clip) ? (
          <ul className="mt-3 flex flex-col gap-1 rounded-card-sm bg-subtle p-3 text-caption text-text-2">
            {d.pools
              .filter((p) => p.max_per_clip)
              .map((p) => (
                <li key={p.pool_id} className="tnum">
                  {t('detail.cap', { amount: capText(p) })}
                </li>
              ))}
          </ul>
        ) : null}
        <Button href={`/leaderboard?tab=campaign&campaign=${c.id}`} linkAs={Link} variant="ghost" size="sm" iconLeft="leaderboard" className="self-start">
          {t('detail.leaderboard')}
        </Button>
      </Card>

      {tags.length ? (
        <Card className="flex flex-col gap-3">
          <CardHeader>
            <CardTitle>{t('detail.tagsTitle')}</CardTitle>
          </CardHeader>
          <ul className="flex flex-wrap gap-1.5">
            {tags.map((tag) => (
              <li key={tag}>
                <Badge tone="primary" className="max-w-full [overflow-wrap:anywhere] whitespace-normal">
                  {tag}
                </Badge>
              </li>
            ))}
          </ul>
          <CopyField value={tags.join(' ')} label={t('detail.copyTags')} copyLabel={t('copy')} copiedLabel={t('copied')} />
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('detail.reqTitle')}</CardTitle>
        </CardHeader>
        <ul className="flex flex-col gap-2 text-body-s text-text-2">
          {requirements.map((r) => (
            <li key={r} className="flex gap-2">
              <Icon name="check_small" size={20} className="shrink-0 text-primary" />
              <span>{r}</span>
            </li>
          ))}
        </ul>
      </Card>

      {c.brief.trim() ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('detail.briefTitle')}</CardTitle>
          </CardHeader>
          <Brief source={c.brief} />
        </Card>
      ) : null}

      {c.dos.length || c.donts.length ? (
        <div className="grid gap-3 sm:grid-cols-2">
          {c.dos.length ? (
            <Card variant="tint">
              <CardHeader>
                <CardTitle>{t('detail.dos')}</CardTitle>
              </CardHeader>
              <ul className="flex flex-col gap-2 text-body-s">
                {c.dos.map((x, i) => (
                  <li key={i} className="flex gap-2">
                    <Icon name="check_circle" size={18} filled className="mt-0.5 shrink-0 text-success" />
                    <span className="[overflow-wrap:anywhere]">{x}</span>
                  </li>
                ))}
              </ul>
            </Card>
          ) : null}
          {c.donts.length ? (
            <Card variant="outline">
              <CardHeader>
                <CardTitle>{t('detail.donts')}</CardTitle>
              </CardHeader>
              <ul className="flex flex-col gap-2 text-body-s">
                {c.donts.map((x, i) => (
                  <li key={i} className="flex gap-2">
                    <Icon name="cancel" size={18} filled className="mt-0.5 shrink-0 text-danger" />
                    <span className="[overflow-wrap:anywhere]">{x}</span>
                  </li>
                ))}
              </ul>
            </Card>
          ) : null}
        </div>
      ) : null}

      {c.example_urls.length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('detail.examples')}</CardTitle>
          </CardHeader>
          <div className="flex flex-col gap-3">
            {c.example_urls.slice(0, 6).map((u) => (
              <EmbedFrame key={u} url={u} title={t('detail.exampleTitle')} openLabel={t('detail.openExample')} />
            ))}
          </div>
        </Card>
      ) : null}

      {files.length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('detail.assets')}</CardTitle>
          </CardHeader>
          <ul className="flex flex-col gap-2">
            {files.map((a) => {
              const href = a.url ?? (a.storage_path ? signedUrl.get(a.storage_path) : null);
              const name = a.url ?? a.storage_path?.split('/').at(-1) ?? a.kind;
              return (
                <li key={a.id} className="flex items-center gap-3 rounded-card-sm border border-border p-2.5">
                  <Icon name={a.kind === 'link' ? 'link' : a.kind === 'video' ? 'movie' : a.kind === 'image' ? 'image' : a.kind === 'audio' ? 'music_note' : 'description'} size={20} className="shrink-0 text-muted" />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-body-s font-semibold text-ink">{name}</span>
                    <span className="text-caption text-muted">
                      {t(`detail.assetKind.${a.kind}`)}
                      {a.size_bytes ? ` · ${formatCompact(a.size_bytes / 1_000_000, locale)} MB` : ''}
                    </span>
                  </span>
                  {href ? (
                    <Button size="sm" variant="secondary" href={href} external={a.kind === 'link'} iconLeft={a.kind === 'link' ? undefined : 'download'} download={a.kind !== 'link' ? '' : undefined} target="_blank" rel="noopener noreferrer">
                      {a.kind === 'link' ? t('detail.open') : t('detail.download')}
                    </Button>
                  ) : (
                    <span className="text-caption text-muted">{t('detail.unavailable')}</span>
                  )}
                </li>
              );
            })}
          </ul>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('detail.timeline')}</CardTitle>
        </CardHeader>
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-body-s">
          <dt className="text-muted">{t('detail.start')}</dt>
          <dd className="text-right font-semibold text-ink tnum">{when(c.start_at)}</dd>
          <dt className="text-muted">{t('detail.deadline')}</dt>
          <dd className="text-right font-semibold text-ink tnum">{when(c.submit_deadline)}</dd>
          <dt className="text-muted">{t('detail.viewWindow')}</dt>
          <dd className="text-right font-semibold text-ink">{t('detail.viewWindowValue', { n: c.view_window_days })}</dd>
          <dt className="text-muted">{t('detail.claimWindow')}</dt>
          <dd className="text-right font-semibold text-ink">{t('detail.claimWindowValue')}</dd>
          {d.my.claim?.status === 'open' ? (
            <>
              <dt className="text-muted">{t('detail.myClaim')}</dt>
              <dd className="text-right font-semibold text-ink tnum">{when(d.my.claim.expires_at)}</dd>
            </>
          ) : null}
        </dl>
      </Card>

      {c.faq.length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('detail.faq')}</CardTitle>
          </CardHeader>
          <div className="flex flex-col divide-y divide-border">
            {c.faq.map((f, i) => (
              <details key={i} className="group py-2.5 first:pt-0 last:pb-0">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-2 rounded-chip text-body-s font-semibold text-ink focus-ring">
                  <span className="[overflow-wrap:anywhere]">{f.q}</span>
                  <Icon name="expand_more" size={20} className="shrink-0 text-muted transition-transform group-open:rotate-180" />
                </summary>
                <p className="mt-1.5 text-body-s whitespace-pre-line text-text-2 [overflow-wrap:anywhere]">{f.a}</p>
              </details>
            ))}
          </div>
        </Card>
      ) : null}

      {d.my.submissions.length ? (
        <Card>
          <CardHeader actions={<Button size="sm" variant="link" href="/tasks" linkAs={Link}>{t('detail.allTasks')}</Button>}>
            <CardTitle>{t('detail.mySubmissions')}</CardTitle>
          </CardHeader>
          <ul className="flex flex-col gap-2">
            {d.my.submissions.map((s) => (
              <li key={s.id} className="flex items-center gap-3 text-body-s">
                <StatusBadge kind="submission" status={s.status} label={t(`status.submission.${s.status}`)} size="sm" />
                <a href={s.url} target="_blank" rel="noopener noreferrer" className="min-w-0 flex-1 truncate text-link">
                  {s.url}
                </a>
                <span className="shrink-0 text-caption text-muted tnum">{t('detail.views', { n: formatCompact(s.counted_views, locale) })}</span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      <DetailCta
        campaignId={c.id}
        state={d.cta_state}
        reason={d.cta_reason}
        reasonText={reasonText}
        claim={d.my.claim?.status === 'open' ? { id: d.my.claim.id, expires_at: d.my.claim.expires_at } : null}
        accounts={(social.data ?? [])
          .filter((a) => isPlatform(a.platform))
          .map((a) => ({ id: a.id ?? '', platform: a.platform as Platform, handle: a.handle ?? '', status: a.status ?? '' }))}
        autoSubmit={sp.submit === '1'}
        initialUrl={httpsUrl(sp.url) ?? undefined}
      />
    </article>
  );
}
