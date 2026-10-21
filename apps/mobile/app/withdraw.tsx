// Tarik saldo (F-C09 / F-C15 / C1.11, C6.1, C6.3) native: checklist KYC + rekening (tersamar dari identity) + saldo,
// jumlah, Batch (gratis, Senin) / Instant (biaya flat, Trust Score), ringkasan, "tahan untuk tarik". Tab Reward: klaim
// non-tunai — field non-PII di sini, field PII (alamat/HP) & rekening tetap di accounts.{domain} (dibuka dengan sesi).
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useMemo, useState } from 'react';
import { Linking, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { nextBatchDate, recipientFields } from '@clipper/clipper-lib/pure';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatDate, formatIDR, formatNumber } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { randomId, requestFulfillment, requestPayout, useLoad, withdrawContext, type RewardUnit } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Alert, Badge, Button, Card, EmptyState, Field, Icon, Row, Txt, type IconName } from '@/ui/core';
import { HoldButton } from '@/ui/hold-button';
import { Screen } from '@/ui/screen';
import { Segmented } from '@/ui/segmented';
import { useToast } from '@/ui/toast';
import { openWeb } from '@/web';

function Radio({ on, title, body, aside, disabled, onPress }: { on: boolean; title: string; body?: string; aside?: string; disabled?: boolean; onPress: () => void }) {
  const { c, radius } = useTheme();
  return (
    <Pressable
      accessibilityRole="radio"
      accessibilityState={{ checked: on, disabled: !!disabled }}
      disabled={disabled}
      onPress={() => (haptic.selection(), onPress())}
      style={{ minHeight: 56, flexDirection: 'row', alignItems: 'center', gap: 12, padding: 12, borderRadius: radius.control, borderWidth: 1.5, borderColor: on ? c.primary : c.borderStrong, backgroundColor: on ? c.primarySoft : c.surface, opacity: disabled ? 0.55 : 1 }}
    >
      <Icon name={on ? 'check_circle' : 'radio_button_unchecked' as IconName} size={22} color={on ? c.primary : c.muted} filled={on} />
      <View style={{ flex: 1 }}>
        <Txt variant="label" weight="700">{title}</Txt>
        {body ? <Txt variant="caption" tone="muted">{body}</Txt> : null}
      </View>
      {aside ? <Txt variant="caption" weight="700" tone="text2">{aside}</Txt> : null}
    </Pressable>
  );
}

function RewardForm({ unit, available, recipientRef, shareConsent, disabled, onDone }: { unit: RewardUnit; available: number; recipientRef: string | null; shareConsent: boolean; disabled: boolean; onDone: () => void }) {
  const t = useTranslations('clipper.withdraw.reward');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const toast = useToast();
  const fields = recipientFields(unit.recipient_schema);
  const fixed = unit.fulfillment === 'code_pool';
  const [raw, setRaw] = useState(fixed ? '1' : '');
  const [values, setValues] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const idem = useMemo(() => randomId(), []);
  const inline = fields.filter((f) => !f.pii);
  const needsRef = fields.some((f) => f.pii);
  const amount = Number(raw.replace(',', '.')) || 0;
  const missing = inline.some((f) => f.required && !values[f.key]?.trim());
  const valid = !disabled && amount > 0 && amount <= available && !missing && (!needsRef || (!!recipientRef && shareConsent)) && (!fixed || amount === 1);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await requestFulfillment({ rewardType: unit.id, amount, recipient: values, recipientRef, idempotency: idem });
    setBusy(false);
    if (!r.ok) return haptic.error(), setError(r.code);
    haptic.success();
    toast({ tone: 'success', title: t('success'), body: t('successBody') });
    onDone();
  };
  return (
    <Card>
      <Row style={{ justifyContent: 'space-between' }}>
        <Txt variant="h6" style={{ flex: 1 }}>{unit.name}</Txt>
        <Badge tone="primary">{formatAmount(available, unit, locale)}</Badge>
      </Row>
      <Txt variant="caption" tone="muted">{t(`mode.${unit.fulfillment}` as 'mode.webhook')}</Txt>
      {error ? <Alert tone="danger">{err(error)}</Alert> : null}
      {fixed ? (
        <Txt variant="bodyS" tone="text2">{t('onePerCode')}</Txt>
      ) : (
        <Field
          label={t('amount', { unit: unit.unit_label || unit.code })}
          keyboardType="decimal-pad"
          value={raw}
          onChangeText={setRaw}
          error={amount > available ? t('aboveBalance') : undefined}
        />
      )}
      {inline.map((f) => (
        <Field key={f.key} label={f.required ? `${f.label} *` : f.label} value={values[f.key] ?? ''} autoCapitalize="none" maxLength={200} onChangeText={(v) => setValues((x) => ({ ...x, [f.key]: v }))} />
      ))}
      {needsRef && !shareConsent ? (
        <Alert tone="warn" title={t('consentTitle')} action={{ label: t('consentAction'), onPress: () => void openWeb('accounts', '/privacy').then(onDone) }}>{t('consentBody')}</Alert>
      ) : needsRef && !recipientRef ? (
        <Alert tone="warn" title={t('recipientTitle')} action={{ label: t('recipientAction'), onPress: () => void openWeb('accounts', `/payout-methods?reward_type=${unit.id}`).then(onDone) }}>{t('recipientBody')}</Alert>
      ) : needsRef ? (
        <Row style={{ justifyContent: 'space-between' }}>
          <Txt variant="caption" tone="successFg">{t('recipientSaved')}</Txt>
          <Button variant="link" size="sm" onPress={() => void openWeb('accounts', `/payout-methods?reward_type=${unit.id}`).then(onDone)}>{t('change')}</Button>
        </Row>
      ) : null}
      <Button full icon="redeem" loading={busy} disabled={!valid} onPress={submit}>{t('submit')}</Button>
    </Card>
  );
}

export default function Withdraw() {
  const t = useTranslations('clipper.withdraw');
  const tm = useTranslations('clipper.mobile');
  const tr = useTranslations('clipper.withdraw.reward');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const toast = useToast();
  const sp = useLocalSearchParams<{ tab?: string; reward_type?: string }>();
  const { c } = useTheme();
  const { claims, refresh } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => withdrawContext(uid), [uid]);
  const [tab, setTab] = useState<'cash' | 'reward'>(sp.tab === 'reward' ? 'reward' : 'cash');
  const [method, setMethod] = useState<string | null>(null);
  const [raw, setRaw] = useState<string | null>(null);
  const [channel, setChannel] = useState<'batch' | 'instant'>('batch');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const idem = useMemo(() => randomId(), []);
  const d = data.data;
  const back = async (path: string) => {
    await openWeb('accounts', path);
    await refresh(); // claim kyc / consent ada di JWT → token baru setelah langkah di web
    await data.reload();
  };
  if (!d) {
    return (
      <Screen title={t('title')}>
        {data.error ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : <Txt tone="muted">{tm('loading')}</Txt>}
      </Screen>
    );
  }
  const kycOk = claims?.kyc === 'approved';
  const nextBatch = formatDate(nextBatchDate(), locale);
  const chosen = method ?? d.methods[0]?.id ?? null;
  const amount = Number((raw ?? (d.available >= d.min ? String(Math.floor(d.available)) : '')).replace(/\D/g, '')) || 0;
  const chargedFee = channel === 'instant' ? d.fee : 0;
  const tooLow = amount > 0 && amount < d.min;
  const tooHigh = amount > d.available;
  const valid = !!chosen && amount >= d.min && !tooHigh && amount - chargedFee > 0 && !d.inactive;
  const checks: { ok: boolean; icon: IconName; label: string; detail: string; action?: { label: string; onPress: () => void } }[] = [
    {
      ok: kycOk,
      icon: 'id_card',
      label: t('check.kyc'),
      detail: t(`kyc.${claims?.kyc ?? 'none'}` as 'kyc.none'),
      action: kycOk || claims?.kyc === 'pending' ? undefined : { label: t('check.kycAction'), onPress: () => void back('/kyc') },
    },
    {
      ok: d.methods.length > 0,
      icon: 'account_balance',
      label: t('check.method'),
      detail: d.methods.length ? t('check.methodCount', { n: d.methods.length }) : t('check.methodNone'),
      action: { label: d.methods.length ? t('check.methodManage') : t('check.methodAction'), onPress: () => void back('/payout-methods') },
    },
    {
      ok: d.available >= d.min,
      icon: 'account_balance_wallet',
      label: t('check.balance'),
      detail: d.available >= d.min ? t('check.balanceOk', { amount: formatIDR(d.available, { locale }) }) : t('check.balanceShort', { amount: formatIDR(d.min - d.available, { locale }), min: formatIDR(d.min, { locale }) }),
    },
  ];
  const submit = async () => {
    if (!valid || !chosen) return;
    setBusy(true);
    setError(null);
    const r = await requestPayout({ method: chosen, amount, channel, idempotency: idem });
    setBusy(false);
    if (!r.ok) return haptic.error(), setError(r.code);
    haptic.success();
    toast({ tone: 'success', title: t('success'), body: channel === 'instant' ? t('successInstant') : t('successBatch', { date: nextBatch }) });
    router.replace('/wallet');
  };
  const rewards = [...d.rewards].sort((a, b) => (a.unit.id === sp.reward_type ? -1 : b.unit.id === sp.reward_type ? 1 : 0));

  return (
    <Screen title={t('title')} refreshing={data.loading} onRefresh={data.reload}>
      {d.inactive ? (
        <Alert tone="danger" title={t('inactiveTitle')} action={d.support ? { label: t('contactSupport'), onPress: () => Linking.openURL(d.support!) } : undefined}>{t('inactiveBody')}</Alert>
      ) : null}
      <Segmented
        label={t('tabs')}
        value={tab}
        onChange={setTab}
        items={[
          { key: 'cash', label: t('tabCash'), icon: 'payments' },
          { key: 'reward', label: t('tabReward'), icon: 'redeem', count: rewards.length || undefined },
        ]}
      />
      {tab === 'cash' ? (
        <>
          {d.methodsError ? <Alert tone="danger">{err(d.methodsError)}</Alert> : null}
          <Card>
            <Txt variant="h6">{t('checklist')}</Txt>
            {checks.map((x) => (
              <Row key={x.label} gap={12} style={{ flexWrap: 'nowrap' }}>
                <View style={{ width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center', backgroundColor: x.ok ? c.successBg : c.subtle }}>
                  <Icon name={x.ok ? 'check' : x.icon} size={18} color={x.ok ? c.successFg : c.muted} />
                </View>
                <View style={{ flex: 1 }}>
                  <Txt variant="bodyS" weight="700">{x.label}</Txt>
                  <Txt variant="caption" tone="muted">{x.detail}</Txt>
                </View>
                {x.action ? <Button variant="link" size="sm" onPress={x.action.onPress}>{x.action.label}</Button> : null}
              </Row>
            ))}
          </Card>
          {kycOk && d.methods.length ? (
            <>
              {error ? <Alert tone="danger">{err(error)}</Alert> : null}
              <View style={{ gap: 8 }} accessibilityRole="radiogroup" accessibilityLabel={t('method')}>
                <Txt variant="label" weight="700">{t('method')}</Txt>
                {d.methods.map((m) => (
                  <Radio key={m.id} on={chosen === m.id} title={`${m.bank.toUpperCase()} **${m.last4}`} body={m.name} aside={m.kind === 'ewallet' ? t('ewallet') : undefined} onPress={() => setMethod(m.id)} />
                ))}
              </View>
              <Field
                label={t('amount')}
                helper={t('amountHelper', { min: formatIDR(d.min, { locale }), max: formatIDR(d.available, { locale }) })}
                error={tooLow ? t('belowMin', { min: formatIDR(d.min, { locale }) }) : tooHigh ? t('aboveBalance') : undefined}
                keyboardType="number-pad"
                value={amount ? formatNumber(amount, locale) : ''}
                onChangeText={setRaw}
                testID="withdraw-amount"
              />
              <Button variant="link" size="sm" onPress={() => setRaw(String(Math.floor(d.available)))}>{t('all')}</Button>
              <View style={{ gap: 8 }} accessibilityRole="radiogroup" accessibilityLabel={t('channel')}>
                <Txt variant="label" weight="700">{t('channel')}</Txt>
                <Radio on={channel === 'batch'} title={t('batch')} body={t('batchBody', { date: nextBatch })} aside={t('free')} onPress={() => setChannel('batch')} />
                <Radio
                  on={channel === 'instant'}
                  title={t('instant')}
                  body={d.instant.enabled ? t('instantBody') : !d.instant.flag ? t('instantOff') : t('instantTrust', { min: d.instant.minTrust, score: d.instant.trust })}
                  aside={formatIDR(d.fee, { locale })}
                  disabled={!d.instant.enabled}
                  onPress={() => setChannel('instant')}
                />
              </View>
              <Card style={{ backgroundColor: c.subtle }}>
                <Row style={{ justifyContent: 'space-between' }}>
                  <Txt variant="bodyS" tone="muted">{t('sumAmount')}</Txt>
                  <Txt variant="bodyS" weight="600">{formatIDR(amount, { locale })}</Txt>
                </Row>
                <Row style={{ justifyContent: 'space-between' }}>
                  <Txt variant="bodyS" tone="muted">{t('sumFee')}</Txt>
                  <Txt variant="bodyS" weight="600">{chargedFee ? `−${formatIDR(chargedFee, { locale })}` : t('free')}</Txt>
                </Row>
                <Row style={{ justifyContent: 'space-between' }}>
                  <Txt variant="bodyS" weight="700">{t('sumReceive')}</Txt>
                  <Txt variant="h6">{formatIDR(Math.max(0, amount - chargedFee), { locale })}</Txt>
                </Row>
              </Card>
              <HoldButton label={busy ? tm('processing') : t('submit')} hint={tm('holdHint')} icon="payments" disabled={!valid || busy} onConfirm={submit} testID="hold-withdraw" />
            </>
          ) : (
            <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{t('completeFirst')}</Txt>
          )}
          <Txt variant="caption" tone="muted">{t('nameRule')}</Txt>
        </>
      ) : rewards.length ? (
        <>
          {rewards.map((b) => (
            <RewardForm
              key={b.unit.id}
              unit={b.unit}
              available={b.available}
              recipientRef={d.recipientOf.get(b.unit.id) ?? null}
              shareConsent={claims?.consent_ok?.share_with_brand === true}
              disabled={d.inactive}
              onDone={() => void (refresh(), data.reload())}
            />
          ))}
          <Row gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
            <Badge>{tr('privacyBadge')}</Badge>
            <Txt variant="caption" tone="muted" style={{ flex: 1 }}>{tr('privacy')}</Txt>
          </Row>
        </>
      ) : (
        <EmptyState icon="redeem" title={tr('emptyTitle')} body={tr('emptyBody')} action={{ label: tr('toWallet'), onPress: () => router.replace({ pathname: '/wallet', params: { tab: 'reward' } }) }} />
      )}
    </Screen>
  );
}
