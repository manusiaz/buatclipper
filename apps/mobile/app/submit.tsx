// C1.8 / F-C06 native (sheet: iOS detent medium → large, Android bottom sheet): pilih akun → pilih video (ditarik API,
// hanya setelah claim; video tanpa hashtag wajib tidak bisa dipilih) atau tempel URL (tetap dicek API). Link dari
// share sheet masuk sebagai ?url= → langsung mode tempel. Sama dengan SubmitSheet web.
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { formatDateTime } from '@clipper/ui/format';
import { platformLabels } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { listVideos, submitContext, submitVideo, useLoad, type VideoItem } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { connectPlatform } from '@/social-connect';
import { useTheme } from '@/theme';
import { Alert, Button, Card, EmptyState, Field, Icon, PlatformIcon, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { useToast } from '@/ui/toast';

const RECONNECT = new Set(['token_expired', 'account_inactive']);

export default function Submit() {
  const { campaignId, claimId, url: shared } = useLocalSearchParams<{ campaignId: string; claimId: string; url?: string }>();
  const t = useTranslations('clipper.submit');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const toast = useToast();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const ctx = useLoad(() => submitContext(claims!.sub, campaignId), [claims?.sub, campaignId]);
  const accounts = ctx.data ?? [];
  const usable = accounts.filter((a) => a.status === 'verified');
  const [accountId, setAccountId] = useState<string | null>(null);
  const [videos, setVideos] = useState<VideoItem[] | null>(null);
  const [picked, setPicked] = useState<string | null>(null);
  const [paste, setPaste] = useState(!!shared);
  const [url, setUrl] = useState(shared ?? '');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);

  useEffect(() => {
    if (!accountId && usable[0]) setAccountId(usable[0].id);
  }, [usable, accountId]);

  const load = async (id: string) => {
    setError(null);
    setPicked(null);
    setLoading(true);
    const r = await listVideos(id, claimId);
    setLoading(false);
    if (r.ok) setVideos(r.data);
    else {
      setVideos(null);
      setError(r.error);
    }
  };
  useEffect(() => {
    if (accountId) void load(accountId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accountId]);

  const account = accounts.find((a) => a.id === accountId) ?? null;
  const reconnect = async () => {
    if (!account) return;
    const r = await connectPlatform(account.platform);
    if (r?.connected) haptic.success();
    await ctx.reload();
    if (accountId) await load(accountId);
  };

  const send = async () => {
    if (!accountId) return;
    setError(null);
    setSending(true);
    const r = await submitVideo({ claimId, accountId, ...(paste ? { url } : { postId: picked ?? '' }) });
    setSending(false);
    if (!r.ok) {
      haptic.error();
      return setError(r.error);
    }
    if (r.data.status === 'rejected') {  // keputusan admin bisa langsung menolak (claim dilepas, org sendiri, kuota)
      haptic.error();
      toast({ tone: 'danger', title: t('rejected'), body: t('rejectedBody') });
    } else {
      haptic.success();
      toast({ tone: 'success', title: t('success'), body: r.data.status === 'tracking' ? t('successTracking') : t('successReview') });
    }
    router.dismissAll();
    router.replace('/clips');
  };

  const canSubmit = !!accountId && (paste ? /^https:\/\/\S+$/.test(url.trim()) : !!picked);
  return (
    <Screen
      title={t('title')}
      footer={
        <Button full size="lg" icon="send" loading={sending} disabled={!canSubmit} onPress={send} testID="submit-video">
          {sending ? t('sending') : t('submit')}
        </Button>
      }
    >
      <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
      {ctx.error && !ctx.data ? <Alert tone="danger" action={{ label: t('refresh'), onPress: ctx.reload }}>{err(ctx.error)}</Alert> : null}
      {error ? (
        <Alert tone="danger" action={RECONNECT.has(error) ? { label: t('reconnect'), onPress: reconnect } : undefined}>
          {err(error)}
        </Alert>
      ) : null}
      {ctx.data && !accounts.length ? (
        <EmptyState icon="link" title={t('noAccountTitle')} body={t('noAccountBody')} action={{ label: t('connect'), onPress: () => router.push({ pathname: '/social', params: { next: `/campaign/${campaignId}` } }) }} />
      ) : (
        <View style={{ gap: 8 }} accessibilityRole="radiogroup" accessibilityLabel={t('account')}>
          <Txt variant="label" weight="600">{t('account')}</Txt>
          {accounts.map((a) => {
            const active = a.id === accountId;
            const off = a.status !== 'verified';
            return (
              <Pressable
                key={a.id}
                accessibilityRole="radio"
                accessibilityState={{ checked: active, disabled: off }}
                onPress={() => (off ? void connectPlatform(a.platform).then(() => ctx.reload()) : setAccountId(a.id))}
                style={{ minHeight: 52, flexDirection: 'row', alignItems: 'center', gap: 10, padding: 12, borderRadius: radius.control, borderWidth: 1.5, borderColor: active ? c.primary : c.borderStrong, backgroundColor: active ? c.primarySoft : c.surface }}
              >
                <PlatformIcon platform={a.platform} size={18} />
                <Txt variant="label" weight="600" style={{ flex: 1, opacity: off ? 0.6 : 1 }}>@{a.handle.replace(/^@/, '')}</Txt>
                {off ? (
                  <Row gap={4}>
                    <Txt variant="caption" tone="warnFg">{t('tokenExpired')}</Txt>
                    <Txt variant="caption" weight="700" tone="link">{t('reconnect')}</Txt>
                  </Row>
                ) : active ? (
                  <Icon name="check_circle" size={20} color={c.primary} filled />
                ) : null}
              </Pressable>
            );
          })}
        </View>
      )}

      {account && !paste ? (
        <View style={{ gap: 8 }} accessibilityLabel={t('videosLabel')}>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="label" weight="600">{t('videos', { platform: platformLabels[account.platform] })}</Txt>
            <Button variant="link" size="sm" icon="refresh" loading={loading} onPress={() => load(account.id)}>{t('refresh')}</Button>
          </Row>
          {loading && !videos
            ? [0, 1, 2].map((i) => <View key={i} style={{ height: 106, borderRadius: radius.card, backgroundColor: c.subtle }} />)
            : null}
          {videos && !videos.length ? <Txt variant="bodyS" tone="muted">{t('noVideos')}</Txt> : null}
          {(videos ?? []).map((v) => {
            const active = picked === v.postId;
            const blocked = v.missingTags.length > 0;
            return (
              <Pressable
                key={v.postId}
                accessibilityRole="radio"
                accessibilityState={{ checked: active, disabled: blocked }}
                disabled={blocked}
                onPress={() => {
                  haptic.selection();
                  setPicked(v.postId);
                }}
              >
                <Card padding={10} style={{ flexDirection: 'row', gap: 10, borderWidth: 1.5, borderColor: blocked ? c.dangerBg : active ? c.primary : c.border, opacity: blocked ? 0.75 : 1 }}>
                  {v.thumbnail ? <Image source={{ uri: v.thumbnail }} style={{ width: 64, height: 86, borderRadius: 10, backgroundColor: c.subtle }} /> : <View style={{ width: 64, height: 86, borderRadius: 10, backgroundColor: c.subtle }} />}
                  <View style={{ flex: 1, gap: 4 }}>
                    <Txt variant="bodyS" numberOfLines={3}>{v.caption || t('noCaption')}</Txt>
                    <Txt variant="caption" tone="muted">
                      {[v.postedAt ? formatDateTime(v.postedAt, locale, { dateStyle: 'medium', timeStyle: 'short' }) : null, v.durationSec != null ? t('seconds', { n: v.durationSec }) : null].filter(Boolean).join(' · ')}
                    </Txt>
                    {blocked ? (
                      <Row gap={4} style={{ flexWrap: 'nowrap' }}>
                        <Icon name="warning" size={14} color={c.danger} filled />
                        <Txt variant="caption" tone="dangerFg" style={{ flex: 1 }}>{t('missing', { tags: v.missingTags.join(', ') })}</Txt>
                      </Row>
                    ) : null}
                  </View>
                  {active ? <Icon name="check_circle" size={20} color={c.primary} filled /> : null}
                </Card>
              </Pressable>
            );
          })}
          {(videos ?? []).some((v) => v.missingTags.length) ? <Txt variant="caption" tone="muted">{t('missingHint')}</Txt> : null}
        </View>
      ) : null}

      {account && paste ? <Field label={t('url')} helper={t('urlHelper')} value={url} onChangeText={setUrl} keyboardType="url" autoCapitalize="none" autoCorrect={false} /> : null}
      {account ? <Button variant="link" onPress={() => setPaste((p) => !p)}>{paste ? t('backToList') : t('pasteUrl')}</Button> : null}
    </Screen>
  );
}
