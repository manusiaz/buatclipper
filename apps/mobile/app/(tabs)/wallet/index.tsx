// Tab Dompet (F-C08 / C1.10, C6.2): saldo Rp Tersedia / Pending (+ estimasi cair) / Ditarik, reward lain per unit,
// riwayat payout, riwayat earning, tab Reward (voucher). Tarik saldo native (/withdraw). DS Motion 25 #7: tarik untuk
// refresh — angka lama tetap tampil, lalu "Update barusan · +Rp…" kalau berubah; offline = data terakhir.
import * as Clipboard from 'expo-clipboard';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { nextBatchDate, num } from '@clipper/clipper-lib/pure';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatDate, formatIDR, formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { useLoad, wallet } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Badge, Button, Card, EmptyState, Icon, Row, Txt } from '@/ui/core';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';
import { Segmented } from '@/ui/segmented';
import { refreshWidgets } from '@/widget';

const PAYOUT_TONE: Record<string, 'success' | 'danger' | 'warn' | 'neutral'> = { paid: 'success', failed: 'danger', cancelled: 'neutral', processing: 'warn', requested: 'warn', on_hold: 'warn' };
const FUL_TONE: Record<string, 'success' | 'danger' | 'warn' | 'neutral'> = { delivered: 'success', cancelled: 'neutral', returned: 'neutral', failed: 'danger' };
const STATE_TONE: Record<string, 'success' | 'warn' | 'neutral' | 'danger'> = { available: 'success', pending: 'warn', held: 'warn', forfeited: 'danger' };

export default function Wallet() {
  const t = useTranslations('clipper.wallet');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const sp = useLocalSearchParams<{ tab?: string }>();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => wallet(uid), [uid], `wallet:${uid}`);
  const [tab, setTab] = useState<'cash' | 'reward'>(sp.tab === 'reward' ? 'reward' : 'cash');
  const [delta, setDelta] = useState<{ at: number; diff: number } | null>(null);
  const before = useRef<number | null>(null);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  useEffect(() => {
    if (!data.data || data.stale) return;
    void refreshWidgets();
    const now = data.data.idr.available;
    if (before.current !== null && before.current !== now) setDelta({ at: Date.now(), diff: now - before.current });
    before.current = now;
  }, [data.data, data.stale]);
  const w = data.data;
  const idr = (v: number) => formatIDR(v, { locale });
  const claimable = (w?.others ?? []).filter((b) => b.available > 0 && b.unit.fulfillment !== 'payout');
  const updated =
    delta && data.updatedAt && data.updatedAt - delta.at < 5_000
      ? tm('updatedDelta', { delta: formatIDR(delta.diff, { locale, signed: true }) })
      : data.updatedAt
        ? tm('updatedAgo', { when: formatRelative(data.updatedAt, Date.now(), locale) })
        : null;

  return (
    <Screen title={tm('tabs.wallet')} tabRoot refreshing={data.loading && !!w} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      {data.error && !w ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {!w && !data.error ? <Txt tone="muted">{tm('loading')}</Txt> : null}
      {w ? (
        <>
          <Segmented
            label={t('tabs')}
            value={tab}
            onChange={setTab}
            items={[
              { key: 'cash', label: t('tabCash'), icon: 'account_balance_wallet' },
              { key: 'reward', label: t('tabReward'), icon: 'redeem', count: w.fulfillments.length || undefined },
            ]}
          />
          {tab === 'cash' ? (
            <>
              <View style={{ backgroundColor: c.navy, borderRadius: radius.card, padding: 18, gap: 6 }}>
                <Row gap={6}>
                  <Icon name="account_balance_wallet" size={18} color="rgba(255,255,255,0.8)" />
                  <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.8)' }}>{t('available')}</Txt>
                </Row>
                <Txt variant="h2" style={{ color: '#ffffff' }} accessibilityLiveRegion="polite">{idr(w.idr.available)}</Txt>
                <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.7)' }}>{t('minHint', { amount: idr(w.min) })}</Txt>
                {updated ? <Txt variant="caption" weight="600" style={{ color: 'rgba(255,255,255,0.85)' }}>{updated}</Txt> : null}
              </View>
              <Row gap={12} style={{ flexWrap: 'nowrap', alignItems: 'stretch' }}>
                <Card style={{ flex: 1 }} padding={14}>
                  <Txt variant="caption" tone="muted">{t('pending')}</Txt>
                  <Txt variant="h5">{idr(w.idr.pending)}</Txt>
                  <Txt variant="caption" tone="muted">{w.idr.pending > 0 && w.nextRelease ? t('releaseHint', { date: formatDate(w.nextRelease, locale) }) : t('pendingHint')}</Txt>
                </Card>
                <Card style={{ flex: 1 }} padding={14}>
                  <Txt variant="caption" tone="muted">{t('withdrawn')}</Txt>
                  <Txt variant="h5">{idr(w.idr.withdrawn)}</Txt>
                </Card>
              </Row>
              <Button full size="lg" variant="ink" icon="payments" disabled={w.idr.available < w.min} onPress={() => router.push('/withdraw')} testID="open-withdraw">
                {t('withdraw')}
              </Button>
              {w.idr.available < w.min ? (
                <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{t('shortBy', { amount: idr(w.min - w.idr.available), min: idr(w.min) })}</Txt>
              ) : null}

              {w.others.length ? (
                <Card>
                  <Txt variant="h6">{t('otherUnits')}</Txt>
                  {w.others.map((b) => (
                    <Row key={b.unit.id} gap={10} style={{ flexWrap: 'nowrap' }}>
                      <View style={{ flex: 1, gap: 2 }}>
                        <Txt variant="label" weight="700" numberOfLines={1}>{b.unit.name}</Txt>
                        <Txt variant="caption" tone="muted">
                          {t('unitLine', { available: formatAmount(b.available, b.unit, locale), pending: formatAmount(b.pending, b.unit, locale), withdrawn: formatAmount(b.withdrawn, b.unit, locale) })}
                        </Txt>
                      </View>
                      {b.available > 0 && b.unit.fulfillment !== 'payout' ? (
                        <Button size="sm" variant="secondary" icon="redeem" onPress={() => router.push({ pathname: '/withdraw', params: { tab: 'reward', reward_type: b.unit.id } })}>
                          {t('claim')}
                        </Button>
                      ) : null}
                    </Row>
                  ))}
                </Card>
              ) : null}

              {w.payouts.length ? (
                <Card>
                  <Txt variant="h6">{t('payouts')}</Txt>
                  {w.payouts.map((p) => (
                    <Row key={p.id} gap={10} style={{ flexWrap: 'nowrap' }}>
                      <View style={{ flex: 1 }}>
                        <Txt variant="bodyS" weight="700">{idr(p.net)}</Txt>
                        <Txt variant="caption" tone="muted">
                          {`${t(`channel.${p.channel}` as 'channel.batch')} · ${
                            p.status === 'requested' && p.channel === 'batch'
                              ? t('waitingBatch', { date: formatDate(nextBatchDate(), locale) })
                              : formatDate(p.paidAt ?? p.createdAt, locale)
                          }`}
                        </Txt>
                      </View>
                      <Badge tone={PAYOUT_TONE[p.status] ?? 'neutral'}>{t(`payoutStatus.${p.status}` as 'payoutStatus.paid')}</Badge>
                    </Row>
                  ))}
                </Card>
              ) : null}

              <Txt variant="h6" accessibilityRole="header">{t('history')}</Txt>
              {w.history.length ? (
                <Card>
                  {w.history.map((e) => {
                    const unit = w.units.get(e.reward_type_id ?? '');
                    const amount = num(e.amount);
                    return (
                      <Row key={String(e.id)} style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
                        <View style={{ flex: 1 }}>
                          <Txt variant="bodyS" weight="600" numberOfLines={1}>{t(`ref.${e.ref_type}` as 'ref.accrual')}</Txt>
                          <Txt variant="caption" tone="muted">{e.created_at ? formatRelative(e.created_at, Date.now(), locale) : ''}</Txt>
                        </View>
                        <View style={{ alignItems: 'flex-end', gap: 2 }}>
                          <Txt variant="label" weight="700" tone={amount > 0 ? 'successFg' : undefined}>{formatAmount(amount, unit, locale, true)}</Txt>
                          {e.state ? <Badge tone={STATE_TONE[e.state] ?? 'neutral'}>{t(`state.${e.state}` as 'state.available')}</Badge> : null}
                        </View>
                      </Row>
                    );
                  })}
                </Card>
              ) : (
                <EmptyState icon="history" title={t('historyEmpty')} body={t('historyEmptyBody')} action={{ label: t('toCampaigns'), onPress: () => router.push('/') }} />
              )}
            </>
          ) : (
            <>
              {claimable.length ? (
                <Button full icon="redeem" onPress={() => router.push({ pathname: '/withdraw', params: { tab: 'reward' } })}>{t('claimReward')}</Button>
              ) : null}
              {w.fulfillments.length ? (
                w.fulfillments.map((f) => (
                  <Card key={f.id} padding={14}>
                    <Row gap={10} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
                      <View style={{ flex: 1 }}>
                        <Txt variant="label" weight="700" numberOfLines={1}>{f.unit?.name ?? t('reward')}</Txt>
                        <Txt variant="caption" tone="muted">{`${formatAmount(f.amount, f.unit, locale)} · ${formatDate(f.createdAt, locale)}`}</Txt>
                      </View>
                      <Badge tone={FUL_TONE[f.status] ?? 'warn'}>{t(`fulfillmentStatus.${f.status}` as 'fulfillmentStatus.delivered')}</Badge>
                    </Row>
                    {f.code ? (
                      <Row gap={8} style={{ flexWrap: 'nowrap', backgroundColor: c.subtle, borderRadius: radius.control, padding: 10 }}>
                        <View style={{ flex: 1 }}>
                          <Txt variant="caption" tone="muted">{t('voucher')}</Txt>
                          <Txt variant="bodyS" weight="700" selectable style={{ fontFamily: 'monospace' }}>{f.code}</Txt>
                        </View>
                        <Button
                          size="sm"
                          variant="secondary"
                          icon="content_copy"
                          onPress={async () => {
                            await Clipboard.setStringAsync(f.code!);
                            haptic.success();
                          }}
                        >
                          {t('copy')}
                        </Button>
                      </Row>
                    ) : null}
                    {!f.code && !['delivered', 'cancelled', 'returned'].includes(f.status) ? (
                      <Txt variant="caption" tone="muted">{t(f.unit?.fulfillment === 'manual_export' ? 'manualHint' : 'processingHint')}</Txt>
                    ) : null}
                    {!f.code && f.status === 'delivered' ? <Txt variant="caption" tone="successFg">{t('deliveredHint')}</Txt> : null}
                  </Card>
                ))
              ) : (
                <EmptyState icon="redeem" title={t('rewardEmpty')} body={t('rewardEmptyBody')} />
              )}
            </>
          )}
        </>
      ) : null}
    </Screen>
  );
}
