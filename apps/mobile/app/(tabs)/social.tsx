// F-C02 / C1.5 native: akun sosmed per platform + status. Hubungkan/Reconnect = OAuth resmi platform di browser sistem
// (app.{domain}/social → /api/oauth/<platform>/start); kembali ke app, daftar dimuat ulang.
import { useFocusEffect } from 'expo-router';
import { useCallback } from 'react';
import { View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { enabledPlatforms } from '@clipper/clipper-lib/pure';
import { formatCompact } from '@clipper/ui/format';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { socialAccounts, useLoad } from '@/data';
import { Badge, Button, Card, EmptyState, PlatformIcon, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { openWeb } from '@/web';

const TONE = { verified: 'success', token_expired: 'warn', revoked: 'danger' } as const;

export default function Social() {
  const t = useTranslations('clipper.social');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const { claims } = useAuth();
  const data = useLoad(() => socialAccounts(claims!.sub), [claims?.sub]);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  const platforms = data.data ? (enabledPlatforms(data.data.flags) as Platform[]) : [];
  const connect = async (p?: Platform) => {
    await openWeb('app', p ? `/api/oauth/${p}/start` : '/social');
    await data.reload();
  };
  return (
    <Screen tabbed refreshing={data.loading && !!data.data} onRefresh={data.reload}>
      <Txt variant="h4" accessibilityRole="header">{t('title')}</Txt>
      <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
      <Txt variant="caption" tone="muted">{tm('connectWeb')}</Txt>
      {data.data && !platforms.length ? <EmptyState icon="link_off" title={t('noneEnabledTitle')} body={t('noneEnabledBody')} /> : null}
      {platforms.map((p) => {
        const list = (data.data?.accounts ?? []).filter((a) => a.platform === p);
        return (
          <Card key={p}>
            <Row style={{ justifyContent: 'space-between' }}>
              <Row gap={8}>
                <PlatformIcon platform={p} size={20} />
                <Txt variant="h6">{platformLabels[p]}</Txt>
              </Row>
              <Txt variant="caption" tone="muted">{t('count', { n: list.length, max: data.data!.max })}</Txt>
            </Row>
            {list.length ? (
              list.map((a) => (
                <Row key={a.id} style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
                  <View style={{ flex: 1 }}>
                    <Txt variant="label" weight="600">@{(a.handle ?? '').replace(/^@/, '')}</Txt>
                    {a.followers != null ? <Txt variant="caption" tone="muted">{t('followers', { n: formatCompact(Number(a.followers), locale) })}</Txt> : null}
                  </View>
                  <Badge tone={TONE[a.status as keyof typeof TONE] ?? 'neutral'}>{t(`status.${a.status}` as 'status.verified')}</Badge>
                  {a.status !== 'verified' ? <Button size="sm" variant="secondary" onPress={() => connect(p)}>{t('reconnect')}</Button> : null}
                </Row>
              ))
            ) : (
              <Txt variant="bodyS" tone="muted">{t('notConnected')}</Txt>
            )}
            {list.length < data.data!.max ? (
              <Button variant={list.length ? 'secondary' : 'primary'} icon="add_link" onPress={() => connect(p)}>
                {list.length ? t('addAnother') : t('connect')}
              </Button>
            ) : (
              <Txt variant="caption" tone="muted">{t('limit')}</Txt>
            )}
          </Card>
        );
      })}
    </Screen>
  );
}
