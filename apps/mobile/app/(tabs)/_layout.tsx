// Nav bawah app clipper (§6.8): Campaign · Tugas · Wallet · Sosmed — sama dengan MobileAppShell PWA.
import { Tabs } from 'expo-router';
import { useTranslations } from 'use-intl';
import { Icon, type IconName } from '@/ui/core';
import { AppHeader } from '@/ui/header';
import { fontFor, useTheme } from '@/theme';

const TABS: { name: string; key: 'campaigns' | 'tasks' | 'wallet' | 'social'; icon: IconName }[] = [
  { name: 'index', key: 'campaigns', icon: 'campaign' },
  { name: 'tasks', key: 'tasks', icon: 'checklist' },
  { name: 'wallet', key: 'wallet', icon: 'account_balance_wallet' },
  { name: 'social', key: 'social', icon: 'link' },
];

export default function TabsLayout() {
  const t = useTranslations('clipper.nav');
  const { c } = useTheme();
  return (
    <Tabs
      screenOptions={{
        header: () => <AppHeader />,
        tabBarActiveTintColor: c.ink,
        tabBarInactiveTintColor: c.muted,
        tabBarStyle: { backgroundColor: c.surface, borderTopColor: c.border, height: 64, paddingTop: 6 },
        tabBarLabelStyle: { fontFamily: fontFor('600'), fontSize: 11 },
        sceneStyle: { backgroundColor: c.canvas },
      }}
    >
      {TABS.map((tab) => (
        <Tabs.Screen
          key={tab.name}
          name={tab.name}
          options={{
            title: t(tab.key),
            tabBarIcon: ({ focused, color }) => <Icon name={tab.icon} size={22} filled={focused} color={String(color)} />,
          }}
        />
      ))}
    </Tabs>
  );
}
