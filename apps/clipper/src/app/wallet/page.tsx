import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import {
  Button,
  Card,
  CardHeader,
  CardTitle,
  CopyField,
  EmptyState,
  RelativeTime,
  StatCard,
  StatusBadge,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  formatDate,
  formatIDR,
} from '@clipper/ui';
import { estimateRelease, nextBatchDate, num } from '@clipper/clipper-lib/pure';
import { core, myClipTerms, readSettings, rewardTypes, uiLocale } from '@/features/lib/server';
import { formatAmount } from '@clipper/clipper-lib/units';
import { balances } from '@/features/wallet/data';

export const metadata: Metadata = { title: 'Wallet' };

type Props = { searchParams: Promise<{ tab?: string }> };

// F-C08 / C1.10, C6.2: saldo per unit (Pending/Tersedia/Ditarik), riwayat, payout, tab Reward (kode voucher).
export default async function WalletPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const sp = await searchParams;
  const uid = claims.sub;
  const db = await core();
  const [t, locale, bal, settings, entries, payouts, fulfillments, live, terms] = await Promise.all([
    getTranslations('clipper.wallet'),
    uiLocale(),
    balances(uid),
    readSettings(['public.finance.min_withdraw_idr']),
    db.from('wallet_entries').select('id,reward_type_id,amount,state,ref_type,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(60),
    db.from('payouts').select('id,amount,fee,channel,status,created_at,paid_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(10),
    db.from('fulfillments').select('id,reward_type_id,amount,status,delivered_ref,created_at,delivered_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(30),
    db.from('submissions').select('campaign_id,platform,posted_at,locked_at,created_at').eq('user_id', uid).in('status', ['tracking', 'flagged', 'locked']).limit(100),
    myClipTerms(),
  ]);
  const min = num(settings['public.finance.min_withdraw_idr']) || 100_000;
  const idr = bal.idr;
  const available = idr?.available ?? 0;
  const ful = fulfillments.data ?? [];
  const [units, codes, windows] = await Promise.all([
    rewardTypes([...(entries.data ?? []).map((e) => e.reward_type_id!), ...ful.map((f) => f.reward_type_id!)]),
    ful.length ? db.from('reward_codes').select('fulfillment_id,code').in('fulfillment_id', ful.map((f) => f.id!)) : Promise.resolve({ data: [] }),
    (live.data ?? []).length
      ? db.from('campaigns').select('id,view_window_days').in('id', [...new Set((live.data ?? []).map((s) => s.campaign_id!))])
      : Promise.resolve({ data: [] }),
  ]);
  const windowOf = new Map((windows.data ?? []).map((c) => [c.id, num(c.view_window_days) || 30]));
  const nextRelease = (live.data ?? [])
    .map((s) => estimateRelease({ locked_at: s.locked_at ?? null, posted_at: s.posted_at ?? null, created_at: s.created_at! }, windowOf.get(s.campaign_id) ?? 30, num(terms[s.platform!]?.hold_days ?? 7)))
    .filter((d) => d.getTime() > Date.now())
    .sort((a, b) => a.getTime() - b.getTime())[0];
  const codeOf = new Map((codes.data ?? []).map((c) => [c.fulfillment_id, c.code]));
  // Riwayat: baris cermin (bucket Ditarik, sisi pending dari release) disembunyikan supaya satu kejadian = satu baris.
  const history = (entries.data ?? []).filter((e) => e.state !== 'withdrawn' && !(e.ref_type === 'release' && num(e.amount) < 0));
  const tab = sp.tab === 'reward' ? 'reward' : 'cash';

  return (
    <div className="flex flex-col gap-4">
      <h1 className="text-h4 text-ink">{t('title')}</h1>
      <Tabs defaultValue={tab}>
        <TabsList variant="pill" fullWidth aria-label={t('tabs')}>
          <TabsTrigger value="cash" icon="account_balance_wallet">
            {t('tabCash')}
          </TabsTrigger>
          <TabsTrigger value="reward" icon="redeem" count={ful.length || undefined}>
            {t('tabReward')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="cash" className="mt-4 flex flex-col gap-4">
          <StatCard
            variant="dark"
            label={t('available')}
            value={formatIDR(available, { locale })}
            icon="account_balance_wallet"
            hint={t('minHint', { amount: formatIDR(min, { locale }) })}
          />
          <div className="grid grid-cols-2 gap-3">
            <StatCard
              label={t('pending')}
              value={formatIDR(idr?.pending ?? 0, { locale })}
              icon="schedule"
              hint={(idr?.pending ?? 0) > 0 && nextRelease ? t('releaseHint', { date: formatDate(nextRelease, locale) }) : t('pendingHint')}
            />
            <StatCard label={t('withdrawn')} value={formatIDR(idr?.withdrawn ?? 0, { locale })} icon="payments" />
          </div>
          {available >= min ? (
            <Button href="/wallet/withdraw" linkAs={Link} variant="ink" size="lg" fullWidth iconLeft="payments">
              {t('withdraw')}
            </Button>
          ) : (
            <div className="flex flex-col gap-1.5">
              <Button variant="ink" size="lg" fullWidth iconLeft="payments" disabled>
                {t('withdraw')}
              </Button>
              <p className="text-center text-caption text-muted">
                {t('shortBy', { amount: formatIDR(min - available, { locale }), min: formatIDR(min, { locale }) })}
              </p>
            </div>
          )}

          {bal.others.length ? (
            <Card>
              <CardHeader>
                <CardTitle>{t('otherUnits')}</CardTitle>
              </CardHeader>
              <ul className="flex flex-col divide-y divide-border">
                {bal.others.map((b) => (
                  <li key={b.unit.id} className="flex flex-wrap items-center gap-3 py-2.5 first:pt-0 last:pb-0">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-body-s font-bold text-ink">{b.unit.name}</p>
                      <p className="text-caption text-muted tnum">
                        {t('unitLine', {
                          available: formatAmount(b.available, b.unit, locale),
                          pending: formatAmount(b.pending, b.unit, locale),
                          withdrawn: formatAmount(b.withdrawn, b.unit, locale),
                        })}
                      </p>
                    </div>
                    {b.available > 0 && b.unit.fulfillment !== 'payout' ? (
                      <Button size="sm" variant="secondary" href={`/wallet/withdraw?tab=reward&reward_type=${b.unit.id}`} linkAs={Link} iconLeft="redeem">
                        {t('claim')}
                      </Button>
                    ) : null}
                  </li>
                ))}
              </ul>
            </Card>
          ) : null}

          {(payouts.data ?? []).length ? (
            <Card>
              <CardHeader>
                <CardTitle>{t('payouts')}</CardTitle>
              </CardHeader>
              <ul className="flex flex-col divide-y divide-border">
                {payouts.data!.map((p) => (
                  <li key={p.id} className="flex items-center gap-3 py-2.5 first:pt-0 last:pb-0">
                    <div className="min-w-0 flex-1">
                      <p className="text-body-s font-bold text-ink tnum">{formatIDR(num(p.amount) - num(p.fee), { locale })}</p>
                      <p className="text-caption text-muted">
                        {t(`channel.${p.channel}`)} ·{' '}
                        {p.status === 'requested' && p.channel === 'batch'
                          ? t('waitingBatch', { date: formatDate(nextBatchDate(), locale) })
                          : p.paid_at
                            ? formatDate(p.paid_at, locale)
                            : formatDate(p.created_at!, locale)}
                      </p>
                    </div>
                    <StatusBadge kind="payout" status={p.status ?? ''} label={t(`payoutStatus.${p.status}`)} size="sm" />
                  </li>
                ))}
              </ul>
            </Card>
          ) : null}

          <Card>
            <CardHeader>
              <CardTitle>{t('history')}</CardTitle>
            </CardHeader>
            {history.length ? (
              <ul className="flex flex-col divide-y divide-border">
                {history.map((e) => {
                  const unit = units.get(e.reward_type_id ?? '');
                  const amt = num(e.amount);
                  return (
                    <li key={e.id} className="flex items-center gap-3 py-2.5 first:pt-0 last:pb-0">
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-body-s font-semibold text-ink">{t(`ref.${e.ref_type}`)}</p>
                        <p className="text-caption text-muted">
                          <RelativeTime value={e.created_at!} locale={locale} />
                        </p>
                      </div>
                      <div className="flex flex-col items-end gap-0.5">
                        <span className={`text-body-s font-bold tnum ${amt > 0 ? 'text-success-fg' : 'text-ink'}`}>
                          {formatAmount(amt, unit, locale, true)}
                        </span>
                        <StatusBadge kind="earning" status={e.state ?? ''} label={t(`state.${e.state}`)} size="sm" plain />
                      </div>
                    </li>
                  );
                })}
              </ul>
            ) : (
              <EmptyState compact icon="history" tone="neutral" title={t('historyEmpty')} body={t('historyEmptyBody')} action={{ label: t('toCampaigns'), href: '/campaigns', linkAs: Link }} />
            )}
          </Card>
        </TabsContent>

        <TabsContent value="reward" className="mt-4 flex flex-col gap-4">
          {bal.others.some((b) => b.available > 0 && b.unit.fulfillment !== 'payout') ? (
            <Button href="/wallet/withdraw?tab=reward" linkAs={Link} fullWidth iconLeft="redeem">
              {t('claimReward')}
            </Button>
          ) : null}
          {ful.length ? (
            <ul className="flex flex-col gap-3">
              {ful.map((f) => {
                const unit = units.get(f.reward_type_id ?? '');
                const code = codeOf.get(f.id);
                return (
                  <li key={f.id}>
                    <Card padding="sm" className="flex flex-col gap-2.5">
                      <div className="flex items-start gap-3">
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-body-s font-bold text-ink">{unit?.name ?? t('reward')}</p>
                          <p className="text-caption text-muted tnum">
                            {formatAmount(num(f.amount), unit, locale)} · {formatDate(f.created_at!, locale)}
                          </p>
                        </div>
                        <StatusBadge kind="fulfillment" status={f.status ?? ''} label={t(`fulfillmentStatus.${f.status}`)} size="sm" />
                      </div>
                      {code ? <CopyField value={code} label={t('voucher')} mono copyLabel={t('copy')} copiedLabel={t('copied')} /> : null}
                      {!code && f.status !== 'delivered' && f.status !== 'cancelled' && f.status !== 'returned' ? (
                        <p className="text-caption text-muted">{t(unit?.fulfillment === 'manual_export' ? 'manualHint' : 'processingHint')}</p>
                      ) : null}
                      {!code && f.status === 'delivered' ? <p className="text-caption text-success-fg">{t('deliveredHint')}</p> : null}
                    </Card>
                  </li>
                );
              })}
            </ul>
          ) : (
            <EmptyState icon="redeem" tone="neutral" title={t('rewardEmpty')} body={t('rewardEmptyBody')} />
          )}
        </TabsContent>
      </Tabs>
    </div>
  );
}
