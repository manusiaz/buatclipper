// Navigasi utama Android (DS Android 01 "nav bar bawah, 4 tujuan, indikator pill biru muda" + window size class):
// compact < 600 dp = navigation bar bawah M3 (pill 64×32 di belakang ikon aktif, ripple, label selalu tampil);
// medium/expanded ≥ 600 dp = navigation rail di kiri (HP lipat dibuka, tablet). Web (uji) memakai yang sama.
import type { Tabs } from 'expo-router';
import type { ComponentProps } from 'react';
import { Pressable, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTheme } from '../theme';
import { Icon, Txt, type IconName } from './core';

type TabBarProps = Parameters<NonNullable<ComponentProps<typeof Tabs>['tabBar']>>[0];

export const RAIL_MIN_WIDTH = 600;
export const useRail = () => useWindowDimensions().width >= RAIL_MIN_WIDTH;

export function M3TabBar({ state, descriptors, navigation, icons }: TabBarProps & { icons: Record<string, IconName> }) {
  const { c } = useTheme();
  const insets = useSafeAreaInsets();
  const rail = useRail();
  const items = state.routes.map((route, index) => {
    const { options } = descriptors[route.key]!;
    const focused = state.index === index;
    const label = String(options.title ?? route.name);
    const onPress = () => {
      const e = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
      if (!focused && !e.defaultPrevented) navigation.navigate(route.name, route.params);
    };
    return (
      <Pressable
        key={route.key}
        accessibilityRole="tab"
        accessibilityState={{ selected: focused }}
        accessibilityLabel={label}
        testID={`tab-${route.name}`}
        onPress={onPress}
        onLongPress={() => navigation.emit({ type: 'tabLongPress', target: route.key })}
        android_ripple={{ color: c.border, borderless: true, radius: 36 }}
        style={rail ? { alignItems: 'center', gap: 4, paddingVertical: 6, width: 80 } : { flex: 1, alignItems: 'center', gap: 4, paddingTop: 12, paddingBottom: 16 }}
      >
        <View style={{ width: 64, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: focused ? c.primarySoft : 'transparent' }}>
          <Icon name={icons[route.name] ?? 'explore'} size={24} filled={focused} color={focused ? c.primarySoftFg : c.text2} />
        </View>
        <Txt variant="caption" weight={focused ? '700' : '600'} style={{ fontSize: 12, color: focused ? c.ink : c.text2 }} numberOfLines={1}>
          {label}
        </Txt>
      </Pressable>
    );
  });
  if (rail) {
    return (
      <View accessibilityRole="tablist" style={{ width: 80 + insets.left, paddingLeft: insets.left, paddingTop: insets.top + 24, gap: 12, alignItems: 'center', backgroundColor: c.surface, borderRightWidth: 1, borderColor: c.border }}>
        {items}
      </View>
    );
  }
  return (
    <View accessibilityRole="tablist" style={{ flexDirection: 'row', paddingBottom: insets.bottom, backgroundColor: c.surface, borderTopWidth: 1, borderColor: c.border }}>
      {items}
    </View>
  );
}
