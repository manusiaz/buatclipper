import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import { REJECT_REASONS } from '@clipper/i18n';
import {
  Alert,
  Badge,
  Button,
  Card,
  Countdown,
  EmptyState,
  Icon,
  PlatformIcon,
  RelativeTime,
  StatusBadge,
  formatDate,
  formatNumber,
  type Platform,
} from '@clipper/ui';
import { Flash } from '@/features/lib/flash';
import { estimateRelease, isPlatform, num, taskGroup, type TaskGroup } from '@/features/lib/pure';
import { core, myClipTerms, rewardTypes, uiLocale } from '@/features/lib/server';
import { formatAmount } from '@/features/lib/units';
import { AppealButton } from '@/features/tasks/appeal-button';

export const metadata: Metadata = { title: 'Tugas' };

type Props = { searchParams: Promise<{ submitted?: string }> };

const GROUPS: TaskGroup[] = ['validating', 'review', 'tracking', 'rejected', 'appeal', 'locked'];

// F-C07 / C1.9: claim aktif + submisi per status, views terakhir, earning pending, alasan reject, banding 1×.
export default async function TasksPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const sp = await searchParams;
  const uid = claims.sub;
  const db = await core();
  const nowIso = new Date().toISOString();
  const [t, tc, locale, terms, openClaims, subs, accounts] = await Promise.all([
    getTranslations('clipper'),
    getTranslations('common'),
    uiLocale(),
    myClipTerms(),
    db.from('claims').select('id,campaign_id,expires_at').eq('user_id', uid).eq('status', 'open').gt('expires_at', nowIso).order('expires_at'),
    db
      .from('submissions')
      .select('id,campaign_id,social_account_id,platform,url,posted_at,status,counted_views,last_views,last_snapshot_at,locked_at,created_at')
      .eq('user_id', uid)
      .order('created_at', { ascending: false })
      .limit(100),
    db.from('social_accounts').select('id,status').eq('user_id', uid),
  ]);
  const list = subs.data ?? [];
  const ids = list.map((s) => s.id!).filter(Boolean);
  const campaignIds = [...new Set([...list.map((s) => s.campaign_id!), ...(openClaims.data ?? []).map((c) => c.campaign_id!)])].filter(Boolean);

  const [campaigns, earnings, decisions] = await Promise.all([
    campaignIds.length ? db.from('campaigns').select('id,title,view_window_days').in('id', campaignIds) : Promise.resolve({ data: [] }),
    ids.length ? db.from('clip_earnings').select('submission_id,pool_id,amount,released_at').in('submission_id', ids) : Promise.resolve({ data: [] }),
    ids.length
      ? db
          .from('review_decisions')
          .select('target_id,decision,reason_code,message,created_at')
          .eq('target_type', 'submission')
          .in('target_id', ids)
          .order('created_at', { ascending: false })
      : Promise.resolve({ data: [] }),
  ]);
  const poolIds = [...new Set((earnings.data ?? []).map((e) => e.pool_id!))].filter(Boolean);
  const pools = poolIds.length ? (await db.from('reward_pools').select('id,reward_type_id').in('id', poolIds)).data ?? [] : [];
  const units = await rewardTypes(pools.map((p) => p.reward_type_id!));
  const poolUnit = new Map(pools.map((p) => [p.id, units.get(p.reward_type_id ?? '')]));
  const campaign = new Map((campaigns.data ?? []).map((c) => [c.id, c]));
  const accountStatus = new Map((accounts.data ?? []).map((a) => [a.id, a.status]));

  const earningOf = (sid: string) => {
    const per = new Map<string, { unit: ReturnType<typeof poolUnit.get>; pending: number; released: number }>();
    for (const e of earnings.data ?? []) {
      if (e.submission_id !== sid) continue;
      const unit = poolUnit.get(e.pool_id);
      const key = unit?.id ?? e.pool_id ?? '';
      const cur = per.get(key) ?? { unit, pending: 0, released: 0 };
      if (e.released_at) cur.released += num(e.amount);
      else cur.pending += num(e.amount);
      per.set(key, cur);
    }
    return [...per.values()].filter((x) => x.pending > 0 || x.released > 0);
  };
  const decisionOf = (sid: string) => (decisions.data ?? []).filter((d) => d.target_id === sid);

  const grouped = new Map<TaskGroup, typeof list>(GROUPS.map((g) => [g, []]));
  for (const s of list) grouped.get(taskGroup(s.status ?? ''))!.push(s);
  const empty = !list.length && !(openClaims.data ?? []).length;
  // Alasan reject: label standar (common.rejectReasons) kalau kodenya dikenal, lalu pesan reviewer, lalu kode mentah.
  const reasonOf = (code: string | null | undefined, message: string | null | undefined) => {
    const label = code && (REJECT_REASONS as readonly string[]).includes(code) ? tc(`rejectReasons.${code}`) : null;
    return { label: label ?? message ?? code ?? '—', detail: label && message ? message : null };
  };

  return (
    <div className="flex flex-col gap-5">
      <h1 className="text-h4 text-ink">{t('tasks.title')}</h1>
      {sp.submitted === '1' ? (
        <>
          <Flash message={t('tasks.submitted')} />
          <Alert tone="success" title={t('tasks.submitted')}>
            {t('tasks.submittedBody')}
          </Alert>
        </>
      ) : null}

      {empty ? (
        <EmptyState
          icon="checklist"
          title={t('tasks.emptyTitle')}
          body={t('tasks.emptyBody')}
          action={{ label: t('tasks.emptyAction'), href: '/campaigns', linkAs: Link }}
        />
      ) : null}

      {(openClaims.data ?? []).length ? (
        <section className="flex flex-col gap-2" aria-labelledby="g-claims">
          <h2 id="g-claims" className="flex items-center gap-2 text-h6 text-ink">
            {t('tasks.groups.claims')} <Badge size="sm">{openClaims.data!.length}</Badge>
          </h2>
          <ul className="flex flex-col gap-2">
            {openClaims.data!.map((c) => (
              <li key={c.id}>
                <Card padding="sm" className="flex flex-col gap-2">
                  <Link href={`/campaigns/${c.campaign_id}`} className="line-clamp-2 text-body-s font-bold text-ink hover:underline">
                    {campaign.get(c.campaign_id)?.title ?? t('tasks.campaign')}
                  </Link>
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <p className="flex items-center gap-1 text-caption text-muted">
                      {t('claim.expiresIn')}
                      <Countdown target={c.expires_at!} locale={locale} withIcon expiredLabel={t('claim.expired')} className="text-ink" />
                    </p>
                    <Button size="sm" variant="ink" iconLeft="upload" href={`/campaigns/${c.campaign_id}?submit=1`} linkAs={Link}>
                      {t('claim.submit')}
                    </Button>
                  </div>
                </Card>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {GROUPS.map((g) => {
        const items = grouped.get(g)!;
        if (!items.length) return null;
        return (
          <section key={g} className="flex flex-col gap-2" aria-labelledby={`g-${g}`}>
            <h2 id={`g-${g}`} className="flex items-center gap-2 text-h6 text-ink">
              {t(`tasks.groups.${g}`)} <Badge size="sm">{items.length}</Badge>
            </h2>
            <p className="-mt-1 text-caption text-muted">{t(`tasks.groupHint.${g}`)}</p>
            <ul className="flex flex-col gap-2">
              {items.map((s) => {
                const camp = campaign.get(s.campaign_id);
                const earned = earningOf(s.id!);
                const decs = decisionOf(s.id!);
                const verdict = decs.find((d) => d.decision !== 'appeal');
                const appealUsed = decs.some((d) => d.decision === 'appeal');
                const paused = (s.status === 'tracking' || s.status === 'flagged') && accountStatus.get(s.social_account_id) !== 'verified';
                const platform = isPlatform(s.platform) ? (s.platform as Platform) : null;
                const release =
                  s.status === 'tracking' || s.status === 'locked' || s.status === 'flagged'
                    ? estimateRelease(
                        { locked_at: s.locked_at ?? null, posted_at: s.posted_at ?? null, created_at: s.created_at! },
                        num(camp?.view_window_days) || 30,
                        num(terms[s.platform!]?.hold_days ?? 7),
                      )
                    : null;
                return (
                  <li key={s.id}>
                    <Card padding="sm" className="flex flex-col gap-2.5">
                      <div className="flex items-start gap-2.5">
                        {platform ? (
                          <span className="grid size-9 shrink-0 place-items-center rounded-chip bg-subtle">
                            <PlatformIcon platform={platform} size={18} decorative={false} title={t(`platforms.${platform}`)} />
                          </span>
                        ) : null}
                        <div className="min-w-0 flex-1">
                          <Link href={`/campaigns/${s.campaign_id}`} className="line-clamp-2 text-body-s font-bold text-ink hover:underline">
                            {camp?.title ?? t('tasks.campaign')}
                          </Link>
                          <a href={s.url ?? '#'} target="_blank" rel="noopener noreferrer" className="block truncate text-caption text-link">
                            {s.url}
                          </a>
                        </div>
                        <StatusBadge kind="submission" status={s.status ?? ''} label={t(`status.submission.${s.status}`)} size="sm" />
                      </div>
                      <dl className="grid grid-cols-2 gap-2 text-caption">
                        <div className="rounded-chip bg-subtle px-2.5 py-2">
                          <dt className="text-muted">{t('tasks.views')}</dt>
                          <dd className="text-body-s font-bold text-ink tnum">{formatNumber(num(s.last_views ?? s.counted_views), locale)}</dd>
                          {s.last_views != null && num(s.last_views) !== num(s.counted_views) ? (
                            <dd className="text-muted tnum">{t('tasks.counted', { n: formatNumber(num(s.counted_views), locale) })}</dd>
                          ) : null}
                          <dd className="text-muted">
                            {s.last_snapshot_at ? (
                              <>
                                {t('tasks.updated')} <RelativeTime value={s.last_snapshot_at} locale={locale} />
                              </>
                            ) : (
                              t('tasks.notTracked')
                            )}
                          </dd>
                        </div>
                        <div className="rounded-chip bg-subtle px-2.5 py-2">
                          <dt className="text-muted">{t('tasks.earning')}</dt>
                          {earned.length ? (
                            earned.map((e, i) => (
                              <dd key={i} className="text-body-s font-bold text-ink tnum">
                                {formatAmount(e.pending + e.released, e.unit, locale)}
                                <span className="ml-1 text-caption font-normal text-muted">
                                  {e.pending > 0 ? t('tasks.pending') : t('tasks.released')}
                                </span>
                              </dd>
                            ))
                          ) : (
                            <dd className="text-body-s font-bold text-muted">—</dd>
                          )}
                          {release && earned.some((e) => e.pending > 0) ? (
                            <dd className="text-muted">{t('tasks.releaseAt', { date: formatDate(release, locale) })}</dd>
                          ) : null}
                        </div>
                      </dl>
                      {paused && platform ? (
                        <Alert
                          tone="warn"
                          action={{ label: t('tasks.reconnect'), href: `/api/oauth/${platform}/start?next=%2Ftasks` }}
                        >
                          {t('tasks.paused')}
                        </Alert>
                      ) : null}
                      {s.status === 'flagged' ? <p className="text-caption text-warn-fg">{t('tasks.flagged')}</p> : null}
                      {(s.status === 'rejected' || s.status === 'rejected_final' || s.status === 'forfeited') && verdict ? (
                        <div className="flex items-start gap-2 rounded-chip bg-danger-bg/60 px-2.5 py-2 text-caption text-danger-fg">
                          <Icon name="info" size={16} filled className="mt-px shrink-0" />
                          <p className="[overflow-wrap:anywhere]">
                            <span className="font-bold">{t('tasks.reason')}</span> {reasonOf(verdict.reason_code, verdict.message).label}
                            {reasonOf(verdict.reason_code, verdict.message).detail ? (
                              <span className="block text-text-2">{reasonOf(verdict.reason_code, verdict.message).detail}</span>
                            ) : null}
                          </p>
                        </div>
                      ) : null}
                      {s.status === 'rejected' ? (
                        appealUsed ? (
                          <p className="text-caption text-muted">{t('tasks.appealUsed')}</p>
                        ) : (
                          <div className="flex items-center justify-between gap-2">
                            <p className="text-caption text-muted">{t('tasks.appealHint')}</p>
                            <AppealButton submissionId={s.id!} />
                          </div>
                        )
                      ) : null}
                      {s.status === 'appealed' ? <p className="text-caption text-muted">{t('tasks.appealPending')}</p> : null}
                    </Card>
                  </li>
                );
              })}
            </ul>
          </section>
        );
      })}

      {!empty ? (
        <Button href="/wallet" linkAs={Link} variant="secondary" iconLeft="account_balance_wallet" className="self-start">
          {t('tasks.toWallet')}
        </Button>
      ) : null}
    </div>
  );
}
