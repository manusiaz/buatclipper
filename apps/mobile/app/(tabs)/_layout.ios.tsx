// iOS (DS iOS 01 "tab bar kaca, ikon terisi pas aktif"; 03 "komponen sistem"): UITabBar asli lewat NativeTabs —
// material blur / Liquid Glass, SF Symbols, tint biru Clipper tanpa pill, menyusut saat scroll turun.
import { NativeTabs } from 'expo-router/unstable-native-tabs';
import { useTranslations } from 'use-intl';
import { TAB_KEYS, TAB_SF } from '@/ui/tabs';
import { useTheme } from '@/theme';

export default function TabsLayout() {
  const t = useTranslations('clipper.mobile.tabs');
  const { c } = useTheme();
  return (
    <NativeTabs tintColor={c.primary} minimizeBehavior="onScrollDown">
      {TAB_KEYS.map(([name, key]) => (
        <NativeTabs.Trigger key={name} name={name}>
          <NativeTabs.Trigger.Icon sf={TAB_SF[name] as never} />
          <NativeTabs.Trigger.Label>{t(key)}</NativeTabs.Trigger.Label>
        </NativeTabs.Trigger>
      ))}
    </NativeTabs>
  );
}
