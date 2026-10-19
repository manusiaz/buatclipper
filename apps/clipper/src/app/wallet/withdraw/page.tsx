import type { Metadata } from 'next';
import Link from 'next/link';
import { getAuth, requireClipper } from '@clipper/auth/server';
import { hosts, kycUrl } from '@clipper/auth';
import { identityApi } from '@clipper/db-identity';
import { getTranslations } from 'next-intl/server';
import {
  Alert,
  Badge,
  Card,
  EmptyState,
  Icon,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  cn,
  formatDate,
  formatIDR,
  type IconName,
} from '@clipper/ui';
import { isUuid, nextBatchDate, num, recipientFields } from '@/features/lib/pure';
import { core, readSettings, uiLocale } from '@/features/lib/server';
import { balances } from '@/features/wallet/data';
import { CashForm } from '@/features/withdraw/cash-form';
import { RewardForm } from '@/features/withdraw/reward-form';

export const metadata: Metadata = { title: 'Tarik saldo' };

type Props = { searchParams: Promise<Record<string, string | undefined>> };

const SELF = `${hosts.app}/wallet/withdraw`;

// F-C09 / F-C15 / C1.11, C6.1, C6.3: checklist KYC + rekening (identity, tersamar) + jumlah + batch/instant; tab Reward.
export default async function WithdrawPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const sp = await searchParams;
  const { supabase } = await getAuth('sso');
  const db = await core();
  const [t, locale, bal, settings, me, feeRule, methods] = await Promise.all([
    getTranslations('clipper.withdraw'),
    uiLocale(),
    balances(claims.sub),
    readSettings(['public.finance.min_withdraw_idr', 'public.flags.instant_withdraw', 'public.finance.instant_min_trust']),
    db.from('my_profile').select('trust_score,status,suspended_until').maybeSingle(),
    db.from('fee_rules').select('instant_withdraw_fee').eq('scope', 'global').maybeSingle(),
    identityApi(supabase).rpc('my_payout_methods'),
  ]);
  const min = num(settings['public.finance.min_withdraw_idr']) || 100_000;
  const minTrust = num(settings['public.finance.instant_min_trust']) || 70;
  const flag = settings['public.flags.instant_withdraw'] === true;
  const trust = num(me.data?.trust_score);
  const fee = num(feeRule.data?.instant_withdraw_fee);
  const kycOk = claims.kyc === 'approved';
  const methodList = (methods.data ?? []).map((m) => ({ id: m.id, bank: m.bank_code, last4: m.account_last4, name: m.account_name, kind: m.kind }));
  const available = bal.idr?.available ?? 0;
  const inactive =
    me.data?.status === 'banned' ||
    me.data?.status === 'closed' ||
    (me.data?.status === 'suspended' && (!me.data.suspended_until || new Date(me.data.suspended_until) > new Date()));
  const payoutUrl = (q: Record<string, string>) =>
    `${hosts.accounts}/payout-methods?${new URLSearchParams({ ...q, next: q.next ?? SELF })}`;
  const tab = sp.tab === 'reward' ? 'reward' : 'cash';

  const checks: { ok: boolean; icon: IconName; label: string; detail: string; href?: string; action?: string }[] = [
    {
      ok: kycOk,
      icon: 'id_card',
      label: t('check.kyc'),
      detail: t(`kyc.${claims.kyc ?? 'none'}`),
      href: kycOk ? undefined : kycUrl(SELF),
      action: claims.kyc === 'pending' ? undefined : t('check.kycAction'),
    },
    {
      ok: methodList.length > 0,
      icon: 'account_balance',
      label: t('check.method'),
      detail: methodList.length ? t('check.methodCount', { n: methodList.length }) : t('check.methodNone'),
      href: payoutUrl({}),
      action: methodList.length ? t('check.methodManage') : t('check.methodAction'),
    },
    {
      ok: available >= min,
      icon: 'account_balance_wallet',
      label: t('check.balance'),
      detail:
        available >= min
          ? t('check.balanceOk', { amount: formatIDR(available, { locale }) })
          : t('check.balanceShort', { amount: formatIDR(min - available, { locale }), min: formatIDR(min, { locale }) }),
    },
  ];

  const rewardOptions = bal.others
    .filter((b) => b.unit.fulfillment !== 'payout' && b.available > 0)
    .map((b) => {
      const back = `${SELF}?tab=reward&reward_type=${b.unit.id}`;
      return {
        id: b.unit.id,
        name: b.unit.name,
        unitLabel: b.unit.unit_label,
        decimals: b.unit.decimals,
        fulfillment: b.unit.fulfillment,
        available: b.available,
        fields: recipientFields(b.unit.recipient_schema),
        recipientRef: sp.reward_type === b.unit.id && isUuid(sp.recipient_ref) ? sp.recipient_ref! : null,
        recipientHref: payoutUrl({ reward_type: b.unit.id, next: back }),
      };
    })
    .sort((a, b) => (a.id === sp.reward_type ? -1 : b.id === sp.reward_type ? 1 : 0));

  return (
    <div className="flex flex-col gap-4">
      {inactive ? (
        <Alert tone="danger" title={t('inactiveTitle')}>
          {t('inactiveBody')}
        </Alert>
      ) : null}
      <Tabs defaultValue={tab}>
        <TabsList variant="pill" fullWidth aria-label={t('tabs')}>
          <TabsTrigger value="cash" icon="payments">
            {t('tabCash')}
          </TabsTrigger>
          <TabsTrigger value="reward" icon="redeem" count={rewardOptions.length || undefined}>
            {t('tabReward')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="cash" className="mt-4 flex flex-col gap-4">
          <Card padding="sm">
            <h2 className="px-1 pb-2 text-h6 text-ink">{t('checklist')}</h2>
            <ul className="flex flex-col divide-y divide-border">
              {checks.map((c) => (
                <li key={c.label} className="flex items-center gap-3 px-1 py-2.5">
                  <span className={cn('grid size-9 shrink-0 place-items-center rounded-full', c.ok ? 'bg-success-bg text-success-fg' : 'bg-subtle text-muted')}>
                    <Icon name={c.ok ? 'check' : c.icon} size={18} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="text-body-s font-bold text-ink">{c.label}</p>
                    <p className="text-caption text-muted">{c.detail}</p>
                  </div>
                  {c.href && c.action ? (
                    <a href={c.href} className="shrink-0 text-caption font-bold text-link hover:underline">
                      {c.action}
                    </a>
                  ) : null}
                </li>
              ))}
            </ul>
          </Card>
          {kycOk && methodList.length ? (
            <CashForm
              methods={methodList}
              available={available}
              min={min}
              fee={fee}
              instant={{
                enabled: flag && trust >= minTrust,
                reason: !flag ? t('instantOff') : trust < minTrust ? t('instantTrust', { min: minTrust, score: trust }) : null,
              }}
              nextBatch={formatDate(nextBatchDate(), locale)}
              disabled={inactive || available < min}
              initialMethod={isUuid(sp.method) ? sp.method : undefined}
            />
          ) : (
            <p className="text-center text-caption text-muted">{t('completeFirst')}</p>
          )}
          <p className="text-caption text-muted">{t('nameRule')}</p>
        </TabsContent>

        <TabsContent value="reward" className="mt-4 flex flex-col gap-4">
          {rewardOptions.length ? (
            rewardOptions.map((o) => <RewardForm key={o.id} option={o} disabled={inactive} />)
          ) : (
            <EmptyState
              icon="redeem"
              tone="neutral"
              title={t('reward.emptyTitle')}
              body={t('reward.emptyBody')}
              action={{ label: t('reward.toWallet'), href: '/wallet?tab=reward', linkAs: Link }}
            />
          )}
          {bal.others.length ? (
            <p className="flex items-center gap-2 text-caption text-muted">
              <Badge size="sm" tone="outline">
                {t('reward.privacyBadge')}
              </Badge>
              {t('reward.privacy')}
            </p>
          ) : null}
        </TabsContent>
      </Tabs>
    </div>
  );
}
