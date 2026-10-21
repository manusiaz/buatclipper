// Kirim clip (DS Android/iOS 01): dari share sheet (link terisi) atau tombol "Kirim clip" (tempel link). Link
// dicocokkan ke claim terbuka lewat platform-nya (matchShare, sama dengan /share web) → 1 tap "Kirim ke <campaign>"
// → Submit dengan link terisi (tetap dicek ke API, F-C06).
import * as Clipboard from 'expo-clipboard';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useState } from 'react';
import { View } from 'react-native';
import { useTranslations } from 'use-intl';
import { matchShare, sharedUrl } from '@clipper/clipper-lib/pure';
import { platformLabels } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { openClaims, useLoad } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Alert, Badge, Button, Card, EmptyState, Field, PlatformIcon, Row, Txt } from '@/ui/core';
import { Countdown } from '@/ui/countdown';
import { Screen } from '@/ui/screen';

type Claim = Awaited<ReturnType<typeof openClaims>>[number];

export default function Share() {
  const params = useLocalSearchParams<{ url?: string; text?: string }>();
  const t = useTranslations('clipper');
  const tm = useTranslations('clipper.mobile');
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const shared = sharedUrl({ url: params.url, text: params.text });
  const [typed, setTyped] = useState('');
  const url = shared ?? sharedUrl({ text: typed });
  const data = useLoad(() => openClaims(claims!.sub), [claims?.sub], `openClaims:${claims?.sub}`);
  const list = data.data ?? [];
  const m = url ? matchShare(url, list) : null;
  const send = (cl: Claim) => {
    haptic.selection();
    router.push({ pathname: '/submit', params: { campaignId: cl.campaignId, claimId: cl.id, url: url! } });
  };
  const paste = async () => {
    const v = await Clipboard.getStringAsync();
    setTyped(v);
    if (sharedUrl({ text: v })) haptic.success();
  };
  const row = (cl: Claim, primary: boolean) => (
    <Card key={cl.id} padding={14} style={primary ? { borderColor: c.primary, borderWidth: 1.5 } : undefined}>
      {primary ? <Badge tone="primary" icon="bolt">{t('share.best')}</Badge> : null}
      <Txt variant="label" weight="700" numberOfLines={2}>{cl.title || t('tasks.campaign')}</Txt>
      <Row style={{ justifyContent: 'space-between' }}>
        <Row gap={4}>
          <Txt variant="caption" tone="muted">{t('claim.expiresIn')}</Txt>
          <Countdown target={cl.expiresAt} />
        </Row>
        <Row gap={4}>{cl.platforms.map((p) => <PlatformIcon key={p} platform={p} size={14} />)}</Row>
      </Row>
      <Button full={primary} size={primary ? 'lg' : 'sm'} variant={primary ? 'primary' : 'secondary'} icon="send" onPress={() => send(cl)} testID={primary ? 'share-best' : undefined}>
        {primary ? t('share.sendTo', { campaign: cl.title || t('tasks.campaign') }) : t('share.pick')}
      </Button>
    </Card>
  );

  return (
    <Screen title={t('share.title')} refreshing={data.loading && !!data.data} onRefresh={data.reload}>
      {!shared ? (
        <Card>
          <Txt variant="h6">{t('share.pasteTitle')}</Txt>
          <Txt variant="bodyS" tone="text2">{t('share.pasteBody')}</Txt>
          <Field label={t('share.link')} value={typed} onChangeText={setTyped} placeholder="https://" autoCapitalize="none" autoCorrect={false} keyboardType="url" maxLength={2000} testID="share-url" />
          <Button variant="secondary" icon="content_paste" onPress={paste}>{t('share.paste')}</Button>
          {typed.trim() && !url ? <Alert tone="warn">{t('share.badBody')}</Alert> : null}
        </Card>
      ) : null}
      {data.error && !data.data ? <EmptyState icon="error" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {data.data && !list.length ? (
        <EmptyState icon="campaign" title={t('share.emptyTitle')} body={t('share.emptyBody')} action={{ label: t('share.browse'), onPress: () => router.navigate('/') }} />
      ) : null}
      {url && m && list.length ? (
        <>
          <View style={{ gap: 6 }}>
            {m.platform ? (
              <Row gap={6}>
                <PlatformIcon platform={m.platform} size={16} />
                <Txt variant="caption" weight="700">{t('share.detected', { platform: platformLabels[m.platform] })}</Txt>
              </Row>
            ) : null}
            <Txt variant="caption" tone="muted" numberOfLines={1} style={{ backgroundColor: c.subtle, borderRadius: radius.control, padding: 10 }}>{url}</Txt>
          </View>
          {m.best ? row(m.best, true) : m.platform ? <Alert tone="warn">{t('share.noMatch', { platform: platformLabels[m.platform] })}</Alert> : <Txt variant="bodyS" tone="text2">{t('share.body')}</Txt>}
          {m.matched.length + m.others.length > (m.best ? 1 : 0) ? (
            <>
              {m.best ? <Txt variant="label" weight="700">{t('share.others')}</Txt> : null}
              {[...m.matched.slice(1), ...m.others].map((cl) => row(cl, false))}
            </>
          ) : null}
        </>
      ) : null}
    </Screen>
  );
}
