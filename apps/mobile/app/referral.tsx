// Ajak teman (F-C16 / C5.1): kode + link {domain}/?ref=, bagikan lewat share sheet sistem, jumlah teman & bonus,
// cara kerja, daftar teman + status bonus. Sama dengan /referral web.
import * as Clipboard from 'expo-clipboard';
import { useRouter } from 'expo-router';
import { useState } from 'react';
import { Share, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatDate } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { referral, useLoad } from '@/data';
import { env } from '@/env';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Badge, Button, Card, EmptyState, Icon, Row, Txt } from '@/ui/core';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';

function CopyRow({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  const t = useTranslations('clipper.referral');
  const { c, radius } = useTheme();
  const [done, setDone] = useState(false);
  return (
    <View style={{ gap: 4 }}>
      <Txt variant="label" weight="600">{label}</Txt>
      <Row gap={8} style={{ flexWrap: 'nowrap', backgroundColor: c.subtle, borderRadius: radius.control, paddingLeft: 12, paddingRight: 4, minHeight: 48 }}>
        <Txt variant="bodyS" weight={mono ? '700' : undefined} selectable numberOfLines={1} style={{ flex: 1, fontFamily: mono ? 'monospace' : undefined }}>{value}</Txt>
        <Button
          size="sm"
          variant="ghost"
          icon={done ? 'check_circle' : 'content_copy'}
          onPress={async () => {
            await Clipboard.setStringAsync(value);
            haptic.success();
            setDone(true);
          }}
        >
          {done ? t('copied') : t('copy')}
        </Button>
      </Row>
    </View>
  );
}

export default function Referral() {
  const t = useTranslations('clipper.referral');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => referral(uid), [uid], `referral:${uid}`);
  const d = data.data;
  const link = d ? `${env.webUrl}/?ref=${encodeURIComponent(d.code)}` : '';
  const now = Date.now();
  const status = (f: { qualified_at: string | null; bonus_until: string | null }) =>
    !f.qualified_at
      ? { tone: 'neutral' as const, label: t('statusJoined') }
      : f.bonus_until && new Date(f.bonus_until).getTime() > now
        ? { tone: 'success' as const, label: t('statusActive', { date: formatDate(f.bonus_until, locale) }) }
        : { tone: 'primary' as const, label: t('statusDone') };
  return (
    <Screen title={t('title')} refreshing={data.loading && !!d} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      {data.error && !d ? <EmptyState icon="error" title={t('errorTitle')} body={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {d ? (
        <>
          <View style={{ backgroundColor: c.primary, borderRadius: radius.card, padding: 18, gap: 8 }}>
            <Icon name="group_add" size={32} color="#ffffff" filled />
            <Txt variant="h4" style={{ color: '#ffffff' }}>{t('headline')}</Txt>
            <Txt variant="bodyS" style={{ color: 'rgba(255,255,255,0.9)' }}>{t('body')}</Txt>
          </View>
          <Card>
            <CopyRow label={t('code')} value={d.code} mono />
            <CopyRow label={t('link')} value={link} />
            <Button full icon="share" onPress={() => Share.share({ message: `${t('shareText')} ${link}`, url: link })} testID="share-referral">{t('share')}</Button>
          </Card>
          <Row gap={12} style={{ flexWrap: 'nowrap', alignItems: 'stretch' }}>
            <Card style={{ flex: 1 }} padding={14}>
              <Txt variant="caption" tone="muted">{t('friends')}</Txt>
              <Txt variant="h5">{String(d.friends.length)}</Txt>
              <Txt variant="caption" tone="muted">{t('qualified', { n: d.friends.filter((f) => f.qualified_at).length })}</Txt>
            </Card>
            <Card style={{ flex: 1 }} padding={14}>
              <Txt variant="caption" tone="muted">{t('totalBonus')}</Txt>
              <Txt variant="h6">{d.totals.length ? d.totals.map((x) => formatAmount(x.total, x.unit, locale)).join(' + ') : formatAmount(0, null, locale)}</Txt>
              <Txt variant="caption" tone="muted">{t('bonusHint')}</Txt>
              <Button variant="link" size="sm" onPress={() => router.push('/wallet')}>{t('toWallet')}</Button>
            </Card>
          </Row>
          <Card>
            <Txt variant="h6">{t('howTitle')}</Txt>
            {[t('how1'), t('how2'), t('how3')].map((s, i) => (
              <Row key={i} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
                <Txt variant="bodyS" weight="700">{`${i + 1}.`}</Txt>
                <Txt variant="bodyS" tone="text2" style={{ flex: 1 }}>{s}</Txt>
              </Row>
            ))}
          </Card>
          <Card>
            <Txt variant="h6">{t('listTitle')}</Txt>
            {d.friends.length ? (
              d.friends.map((f, i) => {
                const s = status(f);
                return (
                  <Row key={`${f.referred_username}-${i}`} gap={10} style={{ flexWrap: 'nowrap', borderTopWidth: i ? 1 : 0, borderColor: c.border, paddingTop: i ? 10 : 0 }}>
                    <View style={{ flex: 1 }}>
                      <Txt variant="bodyS" weight="700" numberOfLines={1}>@{f.referred_username}</Txt>
                      {f.created_at ? <Txt variant="caption" tone="muted">{t('joinedAt', { date: formatDate(f.created_at, locale) })}</Txt> : null}
                    </View>
                    <Badge tone={s.tone}>{s.label}</Badge>
                  </Row>
                );
              })
            ) : (
              <EmptyState icon="group_add" title={t('emptyTitle')} body={t('emptyBody')} />
            )}
          </Card>
        </>
      ) : null}
    </Screen>
  );
}
