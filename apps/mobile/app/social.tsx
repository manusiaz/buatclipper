// F-C02 / C1.5 native: akun sosmed per platform (maks N), status, followers. Hubungkan / reconnect = OAuth resmi
// platform di browser in-app (sesi dibawa) → kembali ke app dengan hasilnya: tersambung, galat, panduan IG akun
// pribadi, pilih Page Facebook. YouTube bisa juga lewat kode di deskripsi channel (D-11). Sama dengan /social web.
import * as Clipboard from 'expo-clipboard';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Modal, Platform as RN, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { enabledPlatforms, isPlatform, parsePages } from '@clipper/clipper-lib/pure';
import { formatCompact } from '@clipper/ui/format';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { socialAccounts, useLoad, youtubeCode, youtubeVerify } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { connectPlatform, type ConnectResult } from '@/social-connect';
import { useTheme } from '@/theme';
import { Alert, Badge, Button, Card, EmptyState, Field, Icon, PlatformIcon, Row, Txt } from '@/ui/core';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';
import { useToast } from '@/ui/toast';

const TONE = { verified: 'success', token_expired: 'warn', revoked: 'danger' } as const;

function YoutubeCode({ onDone }: { onDone: () => void }) {
  const t = useTranslations('clipper.social.youtubeCode');
  const ts = useTranslations('clipper.social');
  const tm = useTranslations('clipper.mobile');
  const err = useErrorText();
  const toast = useToast();
  const { c, radius } = useTheme();
  const [open, setOpen] = useState(false);
  const [channel, setChannel] = useState('');
  const [got, setGot] = useState<{ handle: string; code: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async () => {
    setBusy(true);
    setError(null);
    if (!got) {
      const r = await youtubeCode(channel);
      setBusy(false);
      return r.ok ? setGot(r.data) : (haptic.error(), setError(r.error));
    }
    const r = await youtubeVerify(channel);
    setBusy(false);
    if (!r.ok) return haptic.error(), setError(r.error);
    haptic.success();
    toast({ tone: 'success', title: ts('connected', { platform: 'YouTube' }) });
    setOpen(false);
    setGot(null);
    setChannel('');
    onDone();
  };
  return (
    <>
      <Button size="sm" variant="ghost" icon="description" onPress={() => setOpen(true)}>{t('cta')}</Button>
      <Modal visible={open} animationType="slide" presentationStyle={RN.OS === 'ios' ? 'pageSheet' : undefined} onRequestClose={() => setOpen(false)}>
        <Screen>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="h5" accessibilityRole="header">{t('title')}</Txt>
            <Button variant="link" onPress={() => setOpen(false)}>{tm('cancel')}</Button>
          </Row>
          <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
          {error ? <Alert tone="danger">{err(error)}</Alert> : null}
          <Field label={t('channel')} helper={t('channelHelper')} value={channel} maxLength={200} autoCapitalize="none" autoCorrect={false} keyboardType="url" onChangeText={(v) => (setChannel(v), setGot(null))} />
          {got ? (
            <>
              <Row gap={8} style={{ flexWrap: 'nowrap', backgroundColor: c.subtle, borderRadius: radius.control, padding: 12 }}>
                <Txt variant="h6" selectable style={{ flex: 1, fontFamily: 'monospace' }}>{got.code}</Txt>
                <Button size="sm" variant="secondary" icon="content_copy" onPress={async () => (await Clipboard.setStringAsync(got.code), haptic.success())}>{t('copy')}</Button>
              </Row>
              {[t('step1'), t('step2', { handle: `@${got.handle}` }), t('step3')].map((s, i) => (
                <Row key={i} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
                  <Txt variant="bodyS" weight="700">{`${i + 1}.`}</Txt>
                  <Txt variant="bodyS" style={{ flex: 1 }}>{s}</Txt>
                </Row>
              ))}
              <Txt variant="caption" tone="muted">{t('limitNote')}</Txt>
            </>
          ) : null}
          <Button full loading={busy} disabled={!channel.trim()} onPress={run}>{got ? t('verify') : t('getCode')}</Button>
        </Screen>
      </Modal>
    </>
  );
}

export default function Social() {
  const t = useTranslations('clipper.social');
  const tc = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { next } = useLocalSearchParams<{ next?: string }>();
  const toast = useToast();
  const { c } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => socialAccounts(uid), [uid], `social:${uid}`);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  const [result, setResult] = useState<ConnectResult>(null);
  const platforms = data.data ? (enabledPlatforms(data.data.flags) as Platform[]) : [];
  const connect = async (p: Platform, pageId?: string) => {
    const r = await connectPlatform(p, pageId);
    setResult(r);
    if (r?.connected) {
      haptic.success();
      toast({ tone: 'success', title: t('connected', { platform: platformLabels[r.connected as Platform] ?? r.connected }) });
    } else if (r?.error) haptic.error();
    await data.reload();
  };
  const connectedLabel = result?.connected && isPlatform(result.connected) ? platformLabels[result.connected as Platform] : null;
  const errPlatform = result?.platform && isPlatform(result.platform) ? (result.platform as Platform) : null;
  const pages = result?.error === 'page_ambiguous' ? parsePages(result.pages) : [];
  const back = typeof next === 'string' && next.startsWith('/') ? next : null;

  return (
    <Screen title={t('title')} refreshing={data.loading && !!data.data} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
      {data.error && !data.data ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tc('mobile.refresh'), onPress: data.reload }} /> : null}
      {connectedLabel ? (
        <Alert tone="success" title={t('connected', { platform: connectedLabel })} action={back ? { label: t('continue'), onPress: () => router.replace(back as never) } : undefined}>
          {result?.handle ? t('connectedAs', { handle: result.handle }) : ''}
        </Alert>
      ) : null}
      {result?.error && result.error !== 'ig_personal' && result.error !== 'page_ambiguous' ? (
        <Alert tone="danger" title={errPlatform ? t('errorTitle', { platform: platformLabels[errPlatform] }) : undefined}>{err(result.error)}</Alert>
      ) : null}
      {result?.error === 'ig_personal' ? (
        <Card style={{ backgroundColor: c.primarySoft }}>
          <Txt variant="h6">{t('igGuide.title')}</Txt>
          <Txt variant="bodyS" tone="text2">{t('igGuide.body')}</Txt>
          {(['step1', 'step2', 'step3', 'step4'] as const).map((s, i) => (
            <Row key={s} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
              <Txt variant="bodyS" weight="700">{`${i + 1}.`}</Txt>
              <Txt variant="bodyS" tone="text2" style={{ flex: 1 }}>{t(`igGuide.${s}`)}</Txt>
            </Row>
          ))}
          <Button full icon="refresh" onPress={() => connect('instagram')}>{t('igGuide.retry')}</Button>
        </Card>
      ) : null}
      {result?.error === 'page_ambiguous' ? (
        pages.length ? (
          <Card>
            <Txt variant="h6">{t('pickPageTitle')}</Txt>
            <Txt variant="bodyS" tone="text2">{t('pickPageBody')}</Txt>
            {pages.map((p) => (
              <Button key={p.id} full variant="secondary" iconRight="arrow_forward" onPress={() => connect('facebook', p.id)}>{p.name || p.id}</Button>
            ))}
          </Card>
        ) : (
          <Alert tone="danger">{err('page_ambiguous')}</Alert>
        )
      ) : null}

      {data.data && !platforms.length ? <EmptyState icon="link_off" title={t('noneEnabledTitle')} body={t('noneEnabledBody')} /> : null}
      {platforms.map((p) => {
        const list = (data.data?.accounts ?? []).filter((a) => a.platform === p);
        const max = data.data!.max;
        return (
          <Card key={p}>
            <Row gap={12} style={{ flexWrap: 'nowrap' }}>
              <View style={{ width: 44, height: 44, borderRadius: 12, backgroundColor: c.subtle, alignItems: 'center', justifyContent: 'center' }}>
                <PlatformIcon platform={p} size={24} />
              </View>
              <View style={{ flex: 1 }}>
                <Txt variant="h6">{platformLabels[p]}</Txt>
                <Txt variant="caption" tone="muted">{list.length ? t('count', { n: list.length, max }) : t('notConnected')}</Txt>
              </View>
              {list.length < max ? (
                <Button size="sm" variant={list.length ? 'secondary' : 'primary'} icon="add_link" onPress={() => connect(p)} testID={`connect-${p}`}>
                  {list.length ? t('addAnother') : t('connect')}
                </Button>
              ) : (
                <Badge>{t('limit')}</Badge>
              )}
            </Row>
            {p === 'youtube' && (list.length < max || list.some((a) => a.status !== 'verified')) ? <YoutubeCode onDone={data.reload} /> : null}
            {list.map((a) => (
              <Row key={a.id} gap={10} style={{ flexWrap: 'nowrap', borderTopWidth: 1, borderColor: c.border, paddingTop: 10 }}>
                <View style={{ flex: 1, gap: 4 }}>
                  <Txt variant="label" weight="700" numberOfLines={1}>@{(a.handle ?? '').replace(/^@/, '')}</Txt>
                  <Row gap={8}>
                    <Badge tone={TONE[a.status as keyof typeof TONE] ?? 'neutral'}>{t(`status.${a.status}` as 'status.verified')}</Badge>
                    {a.followers != null ? <Txt variant="caption" tone="muted">{t('followers', { n: formatCompact(Number(a.followers), locale) })}</Txt> : null}
                  </Row>
                </View>
                {a.status !== 'verified' ? <Button size="sm" variant="secondary" icon="refresh" onPress={() => connect(p)}>{t('reconnect')}</Button> : null}
              </Row>
            ))}
          </Card>
        );
      })}
      <Row gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
        <Icon name="shield" size={16} color={c.muted} />
        <Txt variant="caption" tone="muted" style={{ flex: 1 }}>{t('privacy')}</Txt>
      </Row>
      {back ? <Button variant="ghost" icon="arrow_back" onPress={() => router.replace(back as never)}>{tc('nav.backToCampaign')}</Button> : null}
    </Screen>
  );
}
