// F-C08 / C1.10 native: saldo Rp (Tersedia / Pending / Ditarik), saldo reward lain, riwayat. Tarik saldo, KYC, dan
// rekening tetap di halaman web (data rekening & NIK hanya diproses identity, accounts.{domain}).
import { useFocusEffect } from 'expo-router';
import { useCallback, useEffect } from 'react';
import { View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { formatAmount } from '@clipper/clipper-lib/units';
import { num } from '@clipper/clipper-lib/pure';
import { formatDateTime, formatIDR } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { useLoad, wallet } from '@/data';
import { useTheme } from '@/theme';
import { Button, Card, EmptyState, Icon, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { refreshBalanceWidget } from '@/widget';
import { openWeb } from '@/web';

export default function Wallet() {
  const t = useTranslations('clipper.wallet');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const { c } = useTheme();
  const { claims } = useAuth();
  const data = useLoad(() => wallet(claims!.sub), [claims?.sub]);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  useEffect(() => {
    if (data.data) void refreshBalanceWidget();
  }, [data.data]);
  const w = data.data;
  const idr = (v: number) => formatIDR(v, { locale });
  return (
    <Screen tabbed refreshing={data.loading && !!w} onRefresh={data.reload}>
      <Txt variant="h4" accessibilityRole="header">{t('title')}</Txt>
      {w ? (
        <>
          <View style={{ backgroundColor: c.navy, borderRadius: 18, padding: 18, gap: 6 }}>
            <Row gap={6}>
              <Icon name="account_balance_wallet" size={18} color="rgba(255,255,255,0.8)" />
              <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.8)' }}>{t('available')}</Txt>
            </Row>
            <Txt variant="h2" style={{ color: '#ffffff' }}>{idr(w.idr.available)}</Txt>
            <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.7)' }}>{t('minHint', { amount: idr(w.min) })}</Txt>
          </View>
          <Row gap={12} style={{ flexWrap: 'nowrap', alignItems: 'stretch' }}>
            <Card style={{ flex: 1 }} padding={14}>
              <Txt variant="caption" tone="muted">{t('pending')}</Txt>
              <Txt variant="h5">{idr(w.idr.pending)}</Txt>
              <Txt variant="caption" tone="muted">{t('pendingHint')}</Txt>
            </Card>
            <Card style={{ flex: 1 }} padding={14}>
              <Txt variant="caption" tone="muted">{t('withdrawn')}</Txt>
              <Txt variant="h5">{idr(w.idr.withdrawn)}</Txt>
            </Card>
          </Row>
          <Button full size="lg" variant="ink" icon="payments" disabled={w.idr.available < w.min} onPress={() => openWeb('app', '/wallet/withdraw')}>
            {t('withdraw')}
          </Button>
          <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>
            {w.idr.available < w.min ? t('shortBy', { amount: idr(w.min - w.idr.available), min: idr(w.min) }) : tm('withdrawWeb')}
          </Txt>
          {w.others.length ? (
            <Card>
              <Txt variant="h6">{t('otherUnits')}</Txt>
              {w.others.map((b) => (
                <View key={b.unit.id} style={{ gap: 2 }}>
                  <Txt variant="label" weight="700">{b.unit.name}</Txt>
                  <Txt variant="caption" tone="muted">
                    {t('unitLine', { available: formatAmount(b.available, b.unit, locale), pending: formatAmount(b.pending, b.unit, locale), withdrawn: formatAmount(b.withdrawn, b.unit, locale) })}
                  </Txt>
                </View>
              ))}
              <Button variant="secondary" size="sm" onPress={() => openWeb('app', '/wallet?tab=reward')}>{t('claim')}</Button>
            </Card>
          ) : null}
          <Txt variant="h6">{t('history')}</Txt>
          {w.history.length ? (
            <Card>
              {w.history.map((e) => {
                const unit = w.units.get(e.reward_type_id ?? '');
                const amount = num(e.amount);
                return (
                  <Row key={String(e.id)} style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
                    <View style={{ flex: 1 }}>
                      <Txt variant="bodyS" weight="600" numberOfLines={1}>{t(`ref.${e.ref_type}` as 'ref.accrual')}</Txt>
                      <Txt variant="caption" tone="muted">{e.created_at ? formatDateTime(e.created_at, locale, { dateStyle: 'medium', timeStyle: 'short' }) : ''}</Txt>
                    </View>
                    <Txt variant="label" weight="700" tone={amount < 0 ? 'danger' : 'successFg'}>{formatAmount(amount, unit, locale, true)}</Txt>
                  </Row>
                );
              })}
            </Card>
          ) : (
            <EmptyState icon="history" title={t('historyEmpty')} body={t('historyEmptyBody')} />
          )}
        </>
      ) : (
        <Txt tone="muted">…</Txt>
      )}
    </Screen>
  );
}
