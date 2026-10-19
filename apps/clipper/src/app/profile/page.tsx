import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import {
  Avatar,
  Button,
  Card,
  CardHeader,
  CardTitle,
  EmptyState,
  Icon,
  ProgressBar,
  StatCard,
  StatusBadge,
  cn,
  formatCompact,
  formatDate,
  formatNumber,
} from '@clipper/ui';
import { arr, num } from '@/features/lib/pure';
import { core, publicUrl, readSettings, uiLocale } from '@/features/lib/server';
import { formatAmount } from '@/features/lib/units';

export const metadata: Metadata = { title: 'Profil & Trust Score' };

// F-C12 / C4.1: statistik, Trust Score 0–100 + efeknya, riwayat perubahan skor (E-40).
export default async function ProfilePage() {
  const { claims } = await requireClipper();
  const db = await core();
  const [t, locale, stats, me, events, settings] = await Promise.all([
    getTranslations('clipper.profile'),
    uiLocale(),
    db.rpc('my_stats'),
    db.from('my_profile').select('username,display_name,avatar_path,trust_score,status,suspended_until,created_at').maybeSingle(),
    db.from('score_events').select('id,delta,reason,created_at').eq('user_id', claims.sub).order('created_at', { ascending: false }).limit(30),
    readSettings(['public.finance.instant_min_trust']),
  ]);
  const s = (stats.data ?? {}) as Record<string, unknown>;
  const score = num(me.data?.trust_score ?? s.trust_score);
  const instantMin = num(settings['public.finance.instant_min_trust']) || 70;
  const earnings = arr<Record<string, unknown>>(s.earnings);
  const name = me.data?.display_name || me.data?.username || claims.email || '';
  // Hanya instant withdraw yang punya ambang config (public.finance.instant_min_trust); efek lain ditentukan per campaign.
  const effects: { key: string; ok: boolean | null }[] = [
    { key: 'instant', ok: score >= instantMin },
    { key: 'premium', ok: null },
    { key: 'cap', ok: null },
    { key: 'hold', ok: null },
  ];

  return (
    <div className="flex flex-col gap-4">
      <Card className="flex items-center gap-4">
        <Avatar name={name || '?'} src={publicUrl('avatars', me.data?.avatar_path)} size={56} />
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-h5 text-ink">{name}</h2>
          {me.data?.username ? <p className="truncate text-body-s text-muted">@{me.data.username}</p> : null}
          {me.data?.created_at ? <p className="text-caption text-muted">{t('since', { date: formatDate(me.data.created_at, locale) })}</p> : null}
        </div>
        {me.data?.status && me.data.status !== 'active' ? (
          <StatusBadge kind="profile" status={me.data.status} label={t(`status.${me.data.status}`)} />
        ) : null}
      </Card>

      <Card variant="dark" className="flex flex-col gap-3">
        <div className="flex items-end justify-between gap-3">
          <div>
            <p className="text-caption text-white/70">{t('trust')}</p>
            <p className="text-[40px] leading-none font-extrabold tnum">
              {score}
              <span className="text-body text-white/60">/100</span>
            </p>
          </div>
          <Icon name="workspace_premium" size={36} filled className="text-white/80" />
        </div>
        <ProgressBar value={score} label={t('trust')} tone={score >= 70 ? 'success' : score >= 40 ? 'warn' : 'danger'} />
        <p className="text-caption text-white/70">{t('trustHint')}</p>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t('effectsTitle')}</CardTitle>
        </CardHeader>
        <ul className="flex flex-col gap-2.5">
          {effects.map((e) => (
            <li key={e.key} className="flex items-start gap-3">
              <span
                className={cn(
                  'grid size-8 shrink-0 place-items-center rounded-full',
                  e.ok ? 'bg-success-bg text-success-fg' : e.ok === null ? 'bg-primary-soft text-primary-soft-fg' : 'bg-subtle text-muted',
                )}
              >
                <Icon name={e.ok ? 'check' : e.ok === null ? 'trending_up' : 'lock'} size={16} />
              </span>
              <div className="min-w-0">
                <p className="text-body-s font-bold text-ink">{t(`effects.${e.key}.title`, { n: instantMin })}</p>
                <p className="text-caption text-muted">{t(`effects.${e.key}.body`, { n: instantMin, score })}</p>
              </div>
            </li>
          ))}
        </ul>
      </Card>

      <div className="grid grid-cols-2 gap-3">
        <StatCard label={t('views')} value={formatCompact(num(s.total_views), locale)} icon="visibility" />
        <StatCard label={t('clips')} value={formatNumber(num(s.clips), locale)} icon="movie" hint={t('campaigns', { n: num(s.campaigns) })} />
        <StatCard
          label={t('approval')}
          value={s.approval_rate == null ? '—' : `${formatNumber(num(s.approval_rate), locale, { maximumFractionDigits: 1 })}%`}
          icon="check_circle"
          hint={t('approvalHint', { approved: num(s.approved), rejected: num(s.rejected) })}
        />
        <StatCard
          label={t('earning')}
          value={
            earnings.length
              ? formatAmount(num(earnings.find((e) => e.code === 'IDR')?.total ?? 0), { code: 'IDR', unit_label: 'Rp' }, locale)
              : formatAmount(0, null, locale)
          }
          icon="payments"
          hint={t('earningHint')}
        />
      </div>

      {earnings.filter((e) => e.code !== 'IDR').length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('otherEarnings')}</CardTitle>
          </CardHeader>
          <ul className="flex flex-col gap-2 text-body-s">
            {earnings
              .filter((e) => e.code !== 'IDR')
              .map((e) => {
                const unit = { code: String(e.code), unit_label: String(e.unit_label ?? ''), decimals: num(e.decimals) };
                return (
                  <li key={String(e.reward_type_id)} className="flex justify-between gap-2 tnum">
                    <span className="text-text-2">{unit.unit_label || unit.code}</span>
                    <span className="font-bold text-ink">{formatAmount(num(e.total), unit, locale)}</span>
                  </li>
                );
              })}
          </ul>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('historyTitle')}</CardTitle>
        </CardHeader>
        {(events.data ?? []).length ? (
          <ul className="flex flex-col divide-y divide-border">
            {events.data!.map((e) => {
              const d = num(e.delta);
              return (
                <li key={e.id} className="flex items-center gap-3 py-2.5 first:pt-0 last:pb-0">
                  <span className={cn('w-12 shrink-0 text-body font-extrabold tnum', d > 0 ? 'text-success-fg' : 'text-danger-fg')}>
                    {d > 0 ? `+${d}` : `−${Math.abs(d)}`}
                  </span>
                  <span className="min-w-0 flex-1 text-body-s text-ink">{t(`reasons.${e.reason}`)}</span>
                  <span className="shrink-0 text-caption text-muted">{e.created_at ? formatDate(e.created_at, locale) : ''}</span>
                </li>
              );
            })}
          </ul>
        ) : (
          <EmptyState compact icon="history" tone="neutral" title={t('historyEmpty')} body={t('historyEmptyBody')} />
        )}
        <p className="mt-3 text-caption text-muted">{t('appealNote')}</p>
      </Card>

      <Button href="/leaderboard" linkAs={Link} variant="secondary" iconLeft="leaderboard" fullWidth>
        {t('toLeaderboard')}
      </Button>
    </div>
  );
}
