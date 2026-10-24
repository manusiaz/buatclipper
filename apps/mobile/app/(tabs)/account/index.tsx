// Tab Akun (menu akun §6.8 + DS "Akun"): profil & Trust Score, akun sosmed (titik merah = perlu perhatian), leaderboard,
// ajak teman, pengaturan; KYC, rekening, privasi & hapus akun di accounts.{domain} (dibuka dengan sesi app);
// komunitas & AI Clip dari setting; keluar (lepas push perangkat + hapus cache).
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Image, Linking, Pressable, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { initials } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { accountHub, useLoad } from '@/data';
import { haptic } from '@/haptics';
import { useTheme } from '@/theme';
import { Badge, Button, Card, Icon, Txt } from '@/ui/core';
import { ListRow, ListSection } from '@/ui/list';
import { Screen } from '@/ui/screen';
import { useToast } from '@/ui/toast';
import { openWeb } from '@/web';

export default function Account() {
  const t = useTranslations('clipper');
  const tm = useTranslations('clipper.mobile');
  const router = useRouter();
  const { c } = useTheme();
  const { claims, signOut } = useAuth();
  const toast = useToast();
  const uid = claims!.sub;
  const hub = useLoad(() => accountHub(uid), [uid], `account:${uid}`);
  useFocusEffect(useCallback(() => void hub.reload(), [hub.reload]));
  const h = hub.data;
  const name = h?.profile?.display_name || h?.profile?.username || claims?.email || '';
  const communityLabel = (key: string) => (['discord', 'whatsapp', 'telegram', 'support'].includes(key) ? t(`menu.community.${key}` as 'menu.community.support') : t('menu.community.other', { name: key }));
  return (
    <Screen title={tm('tabs.account')} tabRoot refreshing={hub.loading && !!h} onRefresh={hub.reload}>
      <Pressable accessibilityRole="button" accessibilityLabel={`${name}, ${t('menu.profile')}`} onPress={() => router.push('/profile')}>
        <Card style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
          {h?.avatar ? (
            <Image source={{ uri: h.avatar }} style={{ width: 56, height: 56, borderRadius: 28 }} />
          ) : (
            <View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
              <Txt variant="h6" style={{ color: c.primarySoftFg }}>{initials(name || '?')}</Txt>
            </View>
          )}
          <View style={{ flex: 1, gap: 2 }}>
            <Txt variant="h6" numberOfLines={1}>{name}</Txt>
            {h?.profile?.username ? <Txt variant="caption" tone="muted">@{h.profile.username}</Txt> : null}
            {h ? <Badge tone={h.trust >= 70 ? 'success' : h.trust >= 40 ? 'warn' : 'danger'} icon="shield">{tm('trustBadge', { score: h.trust })}</Badge> : null}
          </View>
          <Icon name="chevron_right" size={22} color={c.faint} />
        </Card>
      </Pressable>

      <ListSection title={tm('sectionClipper')}>
        <ListRow first icon="link" label={t('nav.social')} detail={h?.socialAttention ? tm('socialAttention') : undefined} dot={h?.socialAttention} onPress={() => router.push('/social')} testID="row-social" />
        <ListRow icon="leaderboard" label={t('menu.leaderboard')} onPress={() => router.push('/leaderboard')} testID="row-leaderboard" />
        <ListRow icon="group_add" label={t('menu.referral')} onPress={() => router.push('/referral')} testID="row-referral" />
        <ListRow icon="settings" label={t('menu.settings')} onPress={() => router.push('/settings')} testID="row-settings" />
      </ListSection>

      <ListSection title={tm('sectionAccount')} footer={tm('accountWebNote')}>
        <ListRow first icon="id_card" label={t('menu.account')} external onPress={() => void openWeb('accounts', '/')} />
        <ListRow icon="account_balance" label={tm('payoutMethods')} external onPress={() => void openWeb('accounts', '/payout-methods')} />
        <ListRow icon="shield" label={tm('privacy')} detail={tm('privacyDetail')} external onPress={() => void openWeb('accounts', '/privacy')} />
      </ListSection>

      {h && (h.community.length || h.aiClip) ? (
        <ListSection title={tm('sectionMore')}>
          {h.aiClip ? <ListRow first icon="movie_edit" label={t('menu.aiClip')} detail={t('menu.aiClipHint')} external onPress={() => Linking.openURL(h.aiClip!)} /> : null}
          {h.community.map((l, i) => (
            <ListRow key={l.key} first={!h.aiClip && i === 0} icon={l.key === 'support' ? 'support_agent' : 'forum'} label={communityLabel(l.key)} external onPress={() => Linking.openURL(l.href)} />
          ))}
        </ListSection>
      ) : null}

      <Button full variant="secondary" icon="logout" onPress={async () => (await signOut()) || (haptic.error(), toast({ tone: 'danger', title: tm('signOutFailed') }))} testID="sign-out">{t('menu.signOut')}</Button>
    </Screen>
  );
}
