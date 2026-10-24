// Header native per platform (DS iOS 03 & Motion 26, Android 03 & Motion 25): iOS = UINavigationBar dengan large title
// yang menyusut ikut scroll, back chevron "‹ <layar sebelumnya>", swipe back; Android = top app bar Material dengan
// panah back sistem (predictive back). Satu tempat supaya semua stack sama.
import type { NativeStackNavigationOptions } from 'expo-router';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Platform, Pressable, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { useAuth } from '../auth';
import { chrome, useLoad } from '../data';
import { fontFor, useTheme } from '../theme';
import { Icon, Txt } from './core';

export function useStackOptions(): NativeStackNavigationOptions {
  const { c } = useTheme();
  return {
    headerTintColor: Platform.OS === 'ios' ? c.primary : c.ink,
    headerTitleStyle: { fontFamily: fontFor('700'), color: c.ink, fontSize: Platform.OS === 'ios' ? 17 : 20 },
    headerLargeTitleStyle: { fontFamily: fontFor('800'), color: c.ink },
    headerBackTitleStyle: { fontFamily: fontFor('500') },
    // Label back iOS = judul layar sebelumnya (UIKit memendekkan ke "Back"/ikon saja bila tak muat).
    headerBackButtonMenuEnabled: true,
    headerShadowVisible: false,
    headerStyle: { backgroundColor: c.canvas },
    // iOS: nav bar jadi material (blur) begitu konten ter-scroll di bawahnya.
    ...(Platform.OS === 'ios' ? { headerTransparent: true, headerBlurEffect: 'systemChromeMaterial' as const, headerLargeTitleShadowVisible: false } : {}),
    contentStyle: { backgroundColor: c.canvas },
    animation: Platform.OS === 'android' ? 'fade_from_bottom' : 'default',
  };
}

/** Opsi layar akar tiap tab: large title di iOS (34 pt → 17 pt inline saat scroll). */
export const tabRootOptions = (title: string): NativeStackNavigationOptions => ({
  title,
  headerLargeTitle: Platform.OS === 'ios',
  headerRight: () => <NotificationsButton />,
});

/** Lonceng notifikasi + jumlah belum dibaca (§6.8), di kanan header layar akar tab. */
export function NotificationsButton() {
  const { c } = useTheme();
  const router = useRouter();
  const t = useTranslations('clipper.nav');
  const { claims } = useAuth();
  const info = useLoad(() => chrome(claims!.sub), [claims?.sub]);
  useFocusEffect(useCallback(() => void info.reload(), [info.reload]));
  const unread = info.data?.unread ?? 0;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={unread ? `${t('notifications')} (${unread})` : t('notifications')}
      onPress={() => router.push('/notifications')}
      hitSlop={8}
      android_ripple={{ color: c.border, borderless: true, radius: 24 }}
      style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}
    >
      <Icon name="notifications" size={24} color={Platform.OS === 'ios' ? c.primary : c.text2} />
      {unread ? (
        <View style={{ position: 'absolute', top: 6, right: 4, minWidth: 18, height: 18, borderRadius: 9, backgroundColor: c.danger, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4 }}>
          <Txt variant="caption" weight="700" tone="primaryFg" style={{ fontSize: 11, lineHeight: 14 }}>{unread > 99 ? '99+' : String(unread)}</Txt>
        </View>
      ) : null}
    </Pressable>
  );
}

/** Tutup modal (iOS: "Batal" di kiri nav bar sheet; Android memakai panah back sistem). */
export function CloseButton() {
  const { c } = useTheme();
  const router = useRouter();
  const t = useTranslations('clipper.mobile');
  return (
    <Pressable accessibilityRole="button" onPress={() => router.back()} hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }}>
      <Txt variant="body" style={{ color: c.primary }}>{t('cancel')}</Txt>
    </Pressable>
  );
}
