// Header app (§6.8): logo, lonceng notifikasi (+ jumlah belum dibaca), avatar → menu akun.
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Image, Pressable, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTranslations } from 'use-intl';
import { initials } from '@clipper/ui/format';
import { useAuth } from '../auth';
import { chrome, useLoad } from '../data';
import { useTheme } from '../theme';
import { Icon, Logo, Txt } from './core';

export function AppHeader() {
  const { c } = useTheme();
  const insets = useSafeAreaInsets();
  const router = useRouter();
  const t = useTranslations('clipper');
  const { claims } = useAuth();
  const info = useLoad(() => chrome(claims!.sub), [claims?.sub]);
  useFocusEffect(useCallback(() => void info.reload(), [info.reload]));
  const unread = info.data?.unread ?? 0;
  const name = info.data?.profile?.display_name || info.data?.profile?.username || claims?.email || '?';
  return (
    <View style={{ paddingTop: insets.top, backgroundColor: c.surface, borderBottomWidth: 1, borderColor: c.border }}>
      <View style={{ height: 56, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Logo size={28} />
        </View>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={unread ? `${t('nav.notifications')} (${unread})` : t('nav.notifications')}
          onPress={() => router.push('/notifications')}
          hitSlop={8}
          style={{ width: 40, height: 40, alignItems: 'center', justifyContent: 'center' }}
        >
          <Icon name="notifications" size={22} color={c.text2} />
          {unread ? (
            <View style={{ position: 'absolute', top: 4, right: 4, minWidth: 18, height: 18, borderRadius: 9, backgroundColor: c.danger, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 }}>
              <Txt variant="caption" weight="700" tone="primaryFg" style={{ fontSize: 11, lineHeight: 14 }}>{unread > 99 ? '99+' : String(unread)}</Txt>
            </View>
          ) : null}
        </Pressable>
        <Pressable accessibilityRole="button" accessibilityLabel={t('menu.open')} onPress={() => router.push('/account')} hitSlop={8}>
          {info.data?.avatar ? (
            <Image source={{ uri: info.data.avatar }} style={{ width: 34, height: 34, borderRadius: 17 }} />
          ) : (
            <View style={{ width: 34, height: 34, borderRadius: 17, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
              <Txt variant="caption" weight="700" style={{ color: c.primarySoftFg }}>{initials(name)}</Txt>
            </View>
          )}
        </Pressable>
      </View>
    </View>
  );
}
