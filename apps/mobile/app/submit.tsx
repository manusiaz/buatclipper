// C1.8 / F-C06 native: pilih akun → pilih video (ditarik API, hanya setelah claim) atau tempel URL (tetap dicek API).
// Link dari share sheet (/share) masuk sebagai ?url= → langsung mode tempel.
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, Pressable, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { platformLabels } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { listVideos, submitContext, submitVideo, useLoad, type VideoItem } from '@/data';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Alert, Button, Card, EmptyState, Field, Icon, PlatformIcon, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';

export default function Submit() {
  const { campaignId, claimId, url: shared } = useLocalSearchParams<{ campaignId: string; claimId: string; url?: string }>();
  const t = useTranslations('clipper.submit');
  const err = useErrorText();
  const router = useRouter();
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
    if (!accountId && usable.length === 1) setAccountId(usable[0]!.id);
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

  const send = async () => {
    if (!accountId) return;
    setError(null);
    setSending(true);
    const r = await submitVideo({ claimId, accountId, ...(paste ? { url: url.trim() } : { postId: picked ?? '' }) });
    setSending(false);
    if (!r.ok) return setError(r.error);
    router.dismissAll();
    router.replace({ pathname: '/tasks', params: { submitted: r.data.status === 'tracking' ? 'tracking' : 'review' } });
  };

  const account = accounts.find((a) => a.id === accountId) ?? null;
  const canSubmit = !!accountId && (paste ? /^https:\/\/\S+$/.test(url.trim()) : !!picked);
  return (
    <Screen
      back
      title={t('title')}
      footer={
        <Button full size="lg" icon="send" loading={sending} disabled={!canSubmit} onPress={send} testID="submit-video">
          {t('submit')}
        </Button>
      }
    >
      <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
      {error ? <Alert tone="danger">{err(error)}</Alert> : null}
      {ctx.data && !accounts.length ? (
        <EmptyState icon="link" title={t('noAccountTitle')} body={t('noAccountBody')} action={{ label: t('connect'), onPress: () => router.push('/social') }} />
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
                disabled={off}
                onPress={() => setAccountId(a.id)}
                style={{ flexDirection: 'row', alignItems: 'center', gap: 10, padding: 12, borderRadius: radius.control, borderWidth: 1.5, borderColor: active ? c.primary : c.borderStrong, backgroundColor: active ? c.primarySoft : c.surface, opacity: off ? 0.6 : 1 }}
              >
                <PlatformIcon platform={a.platform} size={18} />
                <Txt variant="label" weight="600" style={{ flex: 1 }}>@{a.handle.replace(/^@/, '')}</Txt>
                {off ? <Txt variant="caption" tone="warnFg">{t('tokenExpired')}</Txt> : active ? <Icon name="check_circle" size={20} color={c.primary} filled /> : null}
              </Pressable>
            );
          })}
        </View>
      )}

      {account && !paste ? (
        <View style={{ gap: 8 }}>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="label" weight="600">{t('videos', { platform: platformLabels[account.platform] })}</Txt>
            <Button variant="link" size="sm" icon="refresh" loading={loading} onPress={() => load(account.id)}>{t('refresh')}</Button>
          </Row>
          {videos && !videos.length ? <Txt variant="bodyS" tone="muted">{t('noVideos')}</Txt> : null}
          {(videos ?? []).map((v) => {
            const active = picked === v.postId;
            return (
              <Pressable key={v.postId} accessibilityRole="radio" accessibilityState={{ checked: active }} onPress={() => setPicked(v.postId)}>
                <Card padding={10} style={{ flexDirection: 'row', gap: 10, borderWidth: 1.5, borderColor: active ? c.primary : c.border }}>
                  {v.thumbnail ? <Image source={{ uri: v.thumbnail }} style={{ width: 64, height: 86, borderRadius: 10, backgroundColor: c.subtle }} /> : <View style={{ width: 64, height: 86, borderRadius: 10, backgroundColor: c.subtle }} />}
                  <View style={{ flex: 1, gap: 4 }}>
                    <Txt variant="bodyS" numberOfLines={3}>{v.caption || t('noCaption')}</Txt>
                    {v.durationSec != null ? <Txt variant="caption" tone="muted">{t('seconds', { n: v.durationSec })}</Txt> : null}
                    {v.missingTags.length ? <Txt variant="caption" tone="dangerFg">{t('missing', { tags: v.missingTags.join(' ') })}</Txt> : null}
                  </View>
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
