// Tab Clip (F-C07 / C1.9; DS "Clip gua"): claim aktif (belum submit, hitung mundur) + submisi per kelompok status —
// views & kapan update, earning per unit (pending/tersedia) + estimasi cair, tracking terhenti → hubungkan ulang,
// alasan tolak + banding sekali. Aksi utama "Kirim clip": FAB di Android, tombol nav bar di iOS.
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Linking, Platform as RN, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { REJECT_REASONS } from '@clipper/i18n/core';
import { taskGroup, type TaskGroup } from '@clipper/clipper-lib/pure';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatCompact, formatDate, formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { appealSubmission, tasks, useLoad } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { connectPlatform } from '@/social-connect';
import { useTheme } from '@/theme';
import { AppealButton } from '@/ui/appeal';
import { Alert, Badge, Button, Card, EmptyState, Icon, PlatformIcon, Row, Txt } from '@/ui/core';
import { Countdown } from '@/ui/countdown';
import { ExtendedFab } from '@/ui/fab';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';

const GROUPS: TaskGroup[] = ['validating', 'review', 'tracking', 'appeal', 'rejected', 'locked'];
const TONE: Record<TaskGroup, 'success' | 'danger' | 'neutral' | 'warn'> = { validating: 'neutral', review: 'warn', tracking: 'success', appeal: 'warn', rejected: 'danger', locked: 'success' };

export default function Clips() {
  const t = useTranslations('clipper');
  const tc = useTranslations('common');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => tasks(uid), [uid], `tasks:${uid}`);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  const reasonOf = (code: string | null, message: string | null) => {
    const label = code && (REJECT_REASONS as readonly string[]).includes(code) ? tc(`rejectReasons.${code}` as 'rejectReasons.other') : null;
    return { label: label ?? message ?? code ?? '—', detail: label && message ? message : null };
  };
  const send = () => router.push('/share');
  const d = data.data;
  const empty = d && !d.submissions.length && !d.claims.length;

  return (
    <Screen
      title={tm('tabs.clips')}
      tabRoot
      refreshing={data.loading && !!d}
      onRefresh={data.reload}
      banner={<OfflineBanner load={data} />}
      headerRight={RN.OS === 'ios' ? () => <Button variant="link" icon="add_link" onPress={send}>{tm('sendClip')}</Button> : undefined}
      fab={(collapsed) => <ExtendedFab icon="add_link" label={tm('sendClip')} onPress={send} collapsed={collapsed} testID="fab-send" />}
    >
      {data.error && !d ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {!d && !data.error ? <Txt tone="muted">{tm('loading')}</Txt> : null}
      {empty ? <EmptyState icon="checklist" title={t('tasks.emptyTitle')} body={t('tasks.emptyBody')} action={{ label: t('tasks.emptyAction'), onPress: () => router.push('/') }} /> : null}

      {d?.claims.length ? (
        <View style={{ gap: 8 }}>
          <Row gap={8}>
            <Txt variant="h6" accessibilityRole="header">{t('tasks.groups.claims')}</Txt>
            <Badge>{String(d.claims.length)}</Badge>
          </Row>
          {d.claims.map((cl) => (
            <Card key={cl.id} padding={14}>
              <Pressable accessibilityRole="link" onPress={() => router.push({ pathname: '/campaign/[id]', params: { id: cl.campaignId } })}>
                <Txt variant="label" weight="700" numberOfLines={2}>{cl.title || t('tasks.campaign')}</Txt>
              </Pressable>
              <Row style={{ justifyContent: 'space-between' }}>
                <Row gap={4}>
                  <Icon name="schedule" size={14} color={c.muted} />
                  <Txt variant="caption" tone="muted">{t('claim.expiresIn')}</Txt>
                  <Countdown target={cl.expiresAt} />
                </Row>
                <Button size="sm" variant="ink" icon="upload" onPress={() => router.push({ pathname: '/campaign/[id]', params: { id: cl.campaignId, submit: '1' } })}>
                  {t('claim.submit')}
                </Button>
              </Row>
            </Card>
          ))}
        </View>
      ) : null}

      {GROUPS.map((g) => {
        const items = (d?.submissions ?? []).filter((s) => taskGroup(s.status) === g);
        if (!items.length) return null;
        return (
          <View key={g} style={{ gap: 8 }}>
            <Row gap={8}>
              <Txt variant="h6" accessibilityRole="header">{t(`tasks.groups.${g}`)}</Txt>
              <Badge>{String(items.length)}</Badge>
            </Row>
            <Txt variant="caption" tone="muted">{t(`tasks.groupHint.${g}`)}</Txt>
            {items.map((s) => {
              const reason = s.verdict ? reasonOf(s.verdict.code, s.verdict.message) : null;
              return (
                <Card key={s.id} padding={14}>
                  <Row gap={10} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
                    {s.platform ? (
                      <View style={{ width: 36, height: 36, borderRadius: radius.chip, backgroundColor: c.subtle, alignItems: 'center', justifyContent: 'center' }} accessibilityLabel={t(`platforms.${s.platform}` as 'platforms.tiktok')}>
                        <PlatformIcon platform={s.platform} size={18} />
                      </View>
                    ) : null}
                    <View style={{ flex: 1, gap: 2 }}>
                      <Pressable accessibilityRole="link" onPress={() => router.push({ pathname: '/campaign/[id]', params: { id: s.campaignId } })}>
                        <Txt variant="label" weight="700" numberOfLines={2}>{s.title || t('tasks.campaign')}</Txt>
                      </Pressable>
                      {s.url ? (
                        <Pressable accessibilityRole="link" onPress={() => Linking.openURL(s.url)} hitSlop={6}>
                          <Txt variant="caption" tone="link" numberOfLines={1}>{s.url}</Txt>
                        </Pressable>
                      ) : null}
                    </View>
                    <Badge tone={TONE[g]}>{t(`status.submission.${s.status}` as 'status.submission.tracking')}</Badge>
                  </Row>
                  <Row gap={8} style={{ flexWrap: 'nowrap', alignItems: 'stretch' }}>
                    <View style={{ flex: 1, backgroundColor: c.subtle, borderRadius: radius.chip, padding: 10, gap: 2 }}>
                      <Txt variant="caption" tone="muted">{t('tasks.views')}</Txt>
                      <Txt variant="bodyS" weight="700">{formatCompact(s.views, locale)}</Txt>
                      {s.counted != null ? <Txt variant="caption" tone="muted">{t('tasks.counted', { n: formatCompact(s.counted, locale) })}</Txt> : null}
                      <Txt variant="caption" tone="muted">{s.updatedAt ? `${t('tasks.updated')} ${formatRelative(s.updatedAt, Date.now(), locale)}` : t('tasks.notTracked')}</Txt>
                    </View>
                    <View style={{ flex: 1, backgroundColor: c.subtle, borderRadius: radius.chip, padding: 10, gap: 2 }}>
                      <Txt variant="caption" tone="muted">{t('tasks.earning')}</Txt>
                      {s.earned.length ? (
                        s.earned.map((e) => (
                          <Txt key={e.unit?.id ?? 'idr'} variant="bodyS" weight="700">
                            {formatAmount(e.pending + e.released, e.unit, locale)}
                            <Txt variant="caption" tone="muted">{`  ${e.pending > 0 ? t('tasks.pending') : t('tasks.released')}`}</Txt>
                          </Txt>
                        ))
                      ) : (
                        <Txt variant="bodyS" weight="700" tone="muted">—</Txt>
                      )}
                      {s.release && s.earned.some((e) => e.pending > 0) ? <Txt variant="caption" tone="muted">{t('tasks.releaseAt', { date: formatDate(s.release, locale) })}</Txt> : null}
                    </View>
                  </Row>
                  {s.paused && s.platform ? (
                    <Alert
                      tone="warn"
                      action={{
                        label: t('tasks.reconnect'),
                        onPress: async () => {
                          const r = await connectPlatform(s.platform!);
                          if (r?.connected) haptic.success();
                          await data.reload();
                        },
                      }}
                    >
                      {t('tasks.paused')}
                    </Alert>
                  ) : null}
                  {s.status === 'flagged' ? <Txt variant="caption" tone="warnFg">{t('tasks.flagged')}</Txt> : null}
                  {reason && (s.status === 'rejected' || s.status === 'rejected_final' || s.status === 'forfeited') ? (
                    <Row gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start', backgroundColor: c.dangerBg, borderRadius: radius.chip, padding: 10 }}>
                      <Icon name="info" size={16} color={c.dangerFg} filled />
                      <View style={{ flex: 1 }}>
                        <Txt variant="caption" tone="dangerFg">
                          <Txt variant="caption" weight="700" tone="dangerFg">{`${t('tasks.reason')} `}</Txt>
                          {reason.label}
                        </Txt>
                        {reason.detail ? <Txt variant="caption" tone="text2">{reason.detail}</Txt> : null}
                      </View>
                    </Row>
                  ) : null}
                  {s.status === 'rejected' ? (
                    s.appealUsed ? (
                      <Txt variant="caption" tone="muted">{t('tasks.appealUsed')}</Txt>
                    ) : (
                      <Row style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }} gap={8}>
                        <Txt variant="caption" tone="muted" style={{ flex: 1 }}>{t('tasks.appealHint')}</Txt>
                        <AppealButton kind="tasks" send={(m) => appealSubmission(s.id, m)} onDone={data.reload} />
                      </Row>
                    )
                  ) : null}
                  {s.status === 'appealed' ? <Txt variant="caption" tone="muted">{t('tasks.appealPending')}</Txt> : null}
                </Card>
              );
            })}
          </View>
        );
      })}

      {d && !empty ? (
        <Button variant="secondary" icon="account_balance_wallet" onPress={() => router.navigate('/wallet')}>{tm('openWallet')}</Button>
      ) : null}
    </Screen>
  );
}
