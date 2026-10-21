// F-C07 / C1.9 native: claim aktif (belum submit) + submisi per kelompok status, views & earning.
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { taskGroup, type TaskGroup } from '@clipper/clipper-lib/pure';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatCompact, formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { tasks, useLoad } from '@/data';
import { Alert, Badge, Button, Card, EmptyState, PlatformIcon, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';

const GROUPS: TaskGroup[] = ['validating', 'review', 'tracking', 'rejected', 'appeal', 'locked'];

export default function Tasks() {
  const t = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const { submitted } = useLocalSearchParams<{ submitted?: string }>();
  const { claims } = useAuth();
  const data = useLoad(() => tasks(claims!.sub), [claims?.sub]);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  const d = data.data;
  const empty = d && !d.claims.length && !d.submissions.length;
  return (
    <Screen tabbed refreshing={data.loading && !!d} onRefresh={data.reload}>
      <Txt variant="h4" accessibilityRole="header">{t('tasks.title')}</Txt>
      {submitted ? <Alert tone="success" title={t('tasks.submitted')}>{t('tasks.submittedBody')}</Alert> : null}
      {empty ? <EmptyState icon="checklist" title={t('tasks.emptyTitle')} body={t('tasks.emptyBody')} action={{ label: t('tasks.emptyAction'), onPress: () => router.push('/') }} /> : null}
      {d?.claims.length ? (
        <View style={{ gap: 8 }}>
          <Row>
            <Txt variant="h6">{t('tasks.groups.claims')}</Txt>
            <Badge>{String(d.claims.length)}</Badge>
          </Row>
          {d.claims.map((c) => (
            <Card key={c.id} padding={14}>
              <Txt variant="label" weight="700" numberOfLines={2}>{c.title || t('tasks.campaign')}</Txt>
              <Row style={{ justifyContent: 'space-between' }}>
                <Txt variant="caption" tone="muted">{`${t('claim.expiresIn')} ${formatRelative(c.expiresAt, Date.now(), locale)}`}</Txt>
                <Button size="sm" variant="ink" icon="upload" onPress={() => router.push({ pathname: '/campaign/[id]', params: { id: c.campaignId, submit: '1' } })}>
                  {t('claim.submit')}
                </Button>
              </Row>
            </Card>
          ))}
        </View>
      ) : null}
      {GROUPS.map((g) => {
        const list = (d?.submissions ?? []).filter((s) => taskGroup(s.status) === g);
        if (!list.length) return null;
        return (
          <View key={g} style={{ gap: 8 }}>
            <Row>
              <Txt variant="h6">{t(`tasks.groups.${g}`)}</Txt>
              <Badge>{String(list.length)}</Badge>
            </Row>
            <Txt variant="caption" tone="muted">{t(`tasks.groupHint.${g}`)}</Txt>
            {list.map((s) => (
              <Card key={s.id} padding={14}>
                <Row style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
                  <Txt variant="label" weight="700" numberOfLines={1} style={{ flex: 1 }}>{s.title || t('tasks.campaign')}</Txt>
                  <Badge tone={g === 'tracking' || g === 'locked' ? 'success' : g === 'rejected' ? 'danger' : 'neutral'}>{t(`status.submission.${s.status}` as 'status.submission.tracking')}</Badge>
                </Row>
                <Row gap={6}>
                  {s.platform ? <PlatformIcon platform={s.platform} size={14} /> : null}
                  <Txt variant="caption" tone="muted" numberOfLines={1} style={{ flex: 1 }}>{s.url}</Txt>
                </Row>
                <Row style={{ justifyContent: 'space-between' }}>
                  <Txt variant="caption" tone="text2">{`${t('tasks.views')}: ${formatCompact(s.views, locale)}`}</Txt>
                  {s.earned.map((e) => (
                    <Txt key={e.unit?.id ?? e.unit?.code ?? 'idr'} variant="caption" weight="700" tone="successFg">{formatAmount(e.pending + e.released, e.unit, locale)}</Txt>
                  ))}
                </Row>
                {s.counted != null ? <Txt variant="caption" tone="muted">{t('tasks.counted', { n: formatCompact(s.counted, locale) })}</Txt> : null}
              </Card>
            ))}
          </View>
        );
      })}
    </Screen>
  );
}
