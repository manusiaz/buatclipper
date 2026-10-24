// Tujuan utama (DS Android/iOS 01): Campaign · Clip · Dompet · Akun. Android & web: nav bar M3 bawah, rail ≥ 600 dp
// (src/ui/tab-bar.tsx), ganti tab = fade through. iOS: _layout.ios.tsx (UITabBar asli).
import { Tabs } from 'expo-router';
import { useTranslations } from 'use-intl';
import { M3TabBar, useRail } from '@/ui/tab-bar';
import { TAB_ICONS, TAB_KEYS } from '@/ui/tabs';
import { useTheme } from '@/theme';

export default function TabsLayout() {
  const t = useTranslations('clipper.mobile.tabs');
  const { c } = useTheme();
  const rail = useRail();
  return (
    <Tabs
      tabBar={(props) => <M3TabBar {...props} icons={TAB_ICONS} />}
      screenOptions={{
        headerShown: false,
        tabBarPosition: rail ? 'left' : 'bottom',
        animation: 'fade',
        sceneStyle: { backgroundColor: c.canvas },
      }}
    >
      {TAB_KEYS.map(([name, key]) => (
        <Tabs.Screen key={name} name={name} options={{ title: t(key) }} />
      ))}
    </Tabs>
  );
}
