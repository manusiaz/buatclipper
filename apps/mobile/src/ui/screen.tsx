// Kerangka layar native: latar kanvas DS, safe area, scroll + tarik-untuk-muat-ulang, judul opsional & tombol kembali.
import { useRouter } from 'expo-router';
import type { ReactNode } from 'react';
import { Pressable, RefreshControl, ScrollView, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTranslations } from 'use-intl';
import { useTheme } from '../theme';
import { Icon, Txt } from './core';

export function Screen({
  title,
  back,
  right,
  children,
  refreshing,
  onRefresh,
  footer,
  tabbed,
}: {
  title?: string;
  back?: boolean;
  right?: ReactNode;
  children: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  footer?: ReactNode;
  /** Layar tab: nav bawah sudah ada, tidak perlu padding bawah ekstra. */
  tabbed?: boolean;
}) {
  const { c } = useTheme();
  const insets = useSafeAreaInsets();
  const router = useRouter();
  const t = useTranslations('clipper');
  return (
    <View style={{ flex: 1, backgroundColor: c.canvas }}>
      {title || back || right ? (
        <View style={{ paddingTop: tabbed ? 8 : insets.top + 8, paddingHorizontal: 16, paddingBottom: 8, flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          {back ? (
            <Pressable accessibilityRole="button" accessibilityLabel={t('nav.back')} onPress={() => router.back()} hitSlop={10} style={{ width: 40, height: 40, alignItems: 'center', justifyContent: 'center', marginLeft: -8 }}>
              <Icon name="arrow_back" size={22} />
            </Pressable>
          ) : null}
          <View style={{ flex: 1 }}>{title ? <Txt variant="h4" accessibilityRole="header" numberOfLines={1}>{title}</Txt> : null}</View>
          {right}
        </View>
      ) : null}
      <ScrollView
        contentContainerStyle={{ padding: 16, paddingTop: title || back ? 4 : insets.top + 12, paddingBottom: (footer ? 120 : 32) + (tabbed ? 0 : insets.bottom), gap: 14 }}
        refreshControl={onRefresh ? <RefreshControl refreshing={!!refreshing} onRefresh={onRefresh} tintColor={c.primary} /> : undefined}
        keyboardShouldPersistTaps="handled"
      >
        {children}
      </ScrollView>
      {footer ? (
        <View style={{ position: 'absolute', left: 0, right: 0, bottom: 0, padding: 12, paddingBottom: (tabbed ? 12 : insets.bottom + 12), backgroundColor: c.surface, borderTopWidth: 1, borderColor: c.border }}>{footer}</View>
      ) : null}
    </View>
  );
}
