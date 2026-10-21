// Leaderboard (F-C13 / C4.2): mingguan global + per campaign (campaign dari submisi sendiri atau dibuka dari detail);
// baris sendiri disorot dan ditambahkan di bawah kalau di luar top 50. Sama dengan /leaderboard web.
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useState } from 'react';
import { Image, ScrollView, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { num } from '@clipper/clipper-lib/pure';
import { formatCompact, formatDate, initials } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { leaderboard, useLoad, type BoardRow } from '@/data';
import { useErrorText } from '@/i18n';
import { publicUrl } from '@/supabase';
import { useTheme } from '@/theme';
import { Badge, Button, Card, EmptyState, Icon, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';
import { Segmented } from '@/ui/segmented';

function Board({ rows, mine, uid }: { rows: BoardRow[]; mine: BoardRow | null; uid: string }) {
  const t = useTranslations('clipper.leaderboard');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const { c } = useTheme();
  const list = mine && !rows.some((r) => r.user_id === uid) ? [...rows, mine] : rows;
  return (
    <Card padding={0} style={{ overflow: 'hidden', gap: 0 }}>
      {list.map((r, i) => {
        const me = r.user_id === uid;
        const rank = num(r.rank);
        const gap = i > 0 && rank - num(list[i - 1]?.rank) > 1;
        const avatar = publicUrl('avatars', r.avatar_path);
        return (
          <View
            key={`${r.user_id}-${i}`}
            accessibilityLabel={`#${rank} @${r.username ?? '—'}, ${t('views', { n: formatCompact(num(r.views), locale) })}${me ? `, ${t('you')}` : ''}`}
            style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 14, paddingVertical: 12, backgroundColor: me ? c.primarySoft : 'transparent', borderTopWidth: i === 0 ? 0 : gap ? 2 : 1, borderStyle: gap ? 'dashed' : 'solid', borderColor: c.border }}
          >
            <View style={{ width: 32, alignItems: 'center' }}>
              {rank <= 3 ? <Icon name="workspace_premium" size={22} color={c.primary} filled /> : <Txt variant="body" weight="800" tone="muted">{`#${rank}`}</Txt>}
            </View>
            {avatar ? (
              <Image source={{ uri: avatar }} style={{ width: 36, height: 36, borderRadius: 18 }} />
            ) : (
              <View style={{ width: 36, height: 36, borderRadius: 18, backgroundColor: c.subtle, alignItems: 'center', justifyContent: 'center' }}>
                <Txt variant="caption" weight="700">{initials(r.username ?? '?')}</Txt>
              </View>
            )}
            <Txt variant="bodyS" weight="700" numberOfLines={1} style={{ flex: 1 }}>@{r.username ?? '—'}</Txt>
            {me ? <Badge tone="primary">{t('you')}</Badge> : null}
            <Txt variant="bodyS" weight="700">{t('views', { n: formatCompact(num(r.views), locale) })}</Txt>
          </View>
        );
      })}
    </Card>
  );
}

export default function Leaderboard() {
  const t = useTranslations('clipper.leaderboard');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const sp = useLocalSearchParams<{ tab?: string; campaign?: string }>();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const [tab, setTab] = useState<'week' | 'campaign'>(sp.tab === 'campaign' ? 'campaign' : 'week');
  const [campaign, setCampaign] = useState<string | null>(sp.campaign ?? null);
  const data = useLoad(() => leaderboard(uid, campaign), [uid, campaign], `leaderboard:${uid}:${campaign ?? ''}`);
  const d = data.data;
  return (
    <Screen title={t('title')} refreshing={data.loading && !!d} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      <Txt variant="bodyS" tone="muted">{t('description')}</Txt>
      <Segmented
        label={t('tabs')}
        value={tab}
        onChange={setTab}
        items={[
          { key: 'week', label: t('week'), icon: 'calendar_today' },
          { key: 'campaign', label: t('perCampaign'), icon: 'campaign' },
        ]}
      />
      {data.error && !d ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {d && tab === 'week' ? (
        <>
          <Txt variant="caption" tone="muted">{t('weekOf', { date: formatDate(d.week, locale) })}</Txt>
          {d.weekRows.length ? <Board rows={d.weekRows} mine={d.weekMine} uid={uid} /> : <EmptyState icon="leaderboard" title={t('emptyTitle')} body={t('emptyBody')} />}
        </>
      ) : null}
      {d && tab === 'campaign' ? (
        d.options.length && d.selected ? (
          <>
            <Txt variant="label" weight="600">{t('pickCampaign')}</Txt>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
              {d.options.map((o) => (
                <Chip key={o.id} label={o.title.length > 28 ? `${o.title.slice(0, 27)}…` : o.title} active={o.id === d.selected} onPress={() => setCampaign(o.id)} />
              ))}
            </ScrollView>
            {d.campRows.length ? <Board rows={d.campRows} mine={d.campMine} uid={uid} /> : <EmptyState icon="leaderboard" title={t('emptyTitle')} body={t('emptyBody')} />}
            <Button variant="secondary" iconRight="arrow_forward" onPress={() => router.push({ pathname: '/campaign/[id]', params: { id: d.selected! } })}>{t('openCampaign')}</Button>
          </>
        ) : (
          <EmptyState icon="campaign" title={t('noCampaignTitle')} body={t('noCampaignBody')} action={{ label: t('toCampaigns'), onPress: () => router.push('/') }} />
        )
      ) : null}
      <Txt variant="caption" tone="muted">{t('refreshNote')}</Txt>
    </Screen>
  );
}
