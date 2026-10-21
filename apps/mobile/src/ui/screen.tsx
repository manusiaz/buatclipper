// Kerangka layar native: judul & tombol header lewat native-stack (src/ui/nav.tsx), latar kanvas DS, scroll +
// tarik-untuk-muat-ulang (indikator turun, angka lama tetap tampil — DS Motion 25 #7), footer CTA, FAB opsional.
// iOS: contentInsetAdjustmentBehavior automatic → large title menyusut ikut scroll di bawah nav bar material.
import { Stack } from 'expo-router';
import { useRef, useState, type ReactNode } from 'react';
import { Platform, RefreshControl, ScrollView, View, type NativeScrollEvent, type NativeSyntheticEvent } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTheme } from '../theme';
import { tabRootOptions } from './nav';

export function Screen({
  title,
  tabRoot,
  headerRight,
  children,
  refreshing,
  onRefresh,
  footer,
  fab,
  banner,
  onEndReached,
}: {
  title?: string;
  /** Layar akar tab: large title iOS + lonceng notifikasi. */
  tabRoot?: boolean;
  headerRight?: () => ReactNode;
  children: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  footer?: ReactNode;
  /** FAB (Android/web) — menerima status "scroll turun" untuk menyembunyikan label (DS Motion 25 #6). */
  fab?: (collapsed: boolean) => ReactNode;
  /** Pita di atas konten (mis. offline). */
  banner?: ReactNode;
  /** Dekat ujung bawah (± 600 pt) → muat halaman berikutnya (DS: daftar tanpa tombol "muat lagi"). */
  onEndReached?: () => void;
}) {
  const { c } = useTheme();
  const insets = useSafeAreaInsets();
  const [collapsed, setCollapsed] = useState(false);
  const lastY = useRef(0);
  const onScroll =
    fab || onEndReached
      ? (e: NativeSyntheticEvent<NativeScrollEvent>) => {
          const { contentOffset, layoutMeasurement, contentSize } = e.nativeEvent;
          if (onEndReached && contentOffset.y + layoutMeasurement.height >= contentSize.height - 600) onEndReached();
          const y = contentOffset.y;
          if (!fab || Math.abs(y - lastY.current) < 8) return;
          setCollapsed(y > lastY.current && y > 20);
          lastY.current = y;
        }
      : undefined;
  const options = title ? (tabRoot ? tabRootOptions(title) : { title }) : {};
  return (
    <View style={{ flex: 1, backgroundColor: c.canvas }}>
      <Stack.Screen options={headerRight ? { ...options, headerRight } : options} />
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{ padding: 16, gap: 14, paddingBottom: (footer ? 120 : fab ? 96 : 32) + (tabRoot ? 0 : insets.bottom) }}
        refreshControl={onRefresh ? <RefreshControl refreshing={!!refreshing} onRefresh={onRefresh} tintColor={c.primary} colors={[c.primary]} progressBackgroundColor={c.surface} /> : undefined}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode={Platform.OS === 'ios' ? 'interactive' : 'on-drag'}
        onScroll={onScroll}
        scrollEventThrottle={32}
      >
        {banner}
        {children}
      </ScrollView>
      {fab && Platform.OS !== 'ios' ? fab(collapsed) : null}
      {footer ? (
        <View style={{ position: 'absolute', left: 0, right: 0, bottom: 0, padding: 12, paddingBottom: tabRoot ? 12 : insets.bottom + 12, backgroundColor: c.surface, borderTopWidth: 1, borderColor: c.border }}>{footer}</View>
      ) : null}
    </View>
  );
}
