// Root app native: font DS, preferensi, i18n, tema, sesi, share sheet, snackbar; gate rute sama dengan requireClipper
// web. Satu native-stack di atas tab: layar turunan dapat header platform (src/ui/nav.tsx), kirim clip & filter = modal
// (iOS sheet kartu, geser turun untuk tutup; Android layar penuh naik dari bawah).
import { PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_600SemiBold, PlusJakartaSans_700Bold, PlusJakartaSans_800ExtraBold, useFonts } from '@expo-google-fonts/plus-jakarta-sans';
import { Stack, type NativeStackNavigationOptions } from 'expo-router';
import { getFocusedRouteNameFromRoute } from 'expo-router/react-navigation';
import { StatusBar } from 'expo-status-bar';
import { Platform } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { useTranslations } from 'use-intl';
import { AuthProvider, useAuth } from '@/auth';
import { DeviceSync } from '@/device-sync';
import { I18nProvider } from '@/i18n';
import { PrefsProvider, usePrefs } from '@/prefs';
import { PushGate } from '@/push-gate';
import { ShareIntentGate } from '@/share-intent';
import { ThemeProvider, useTheme } from '@/theme';
import { CloseButton, useStackOptions } from '@/ui/nav';
import { TAB_KEYS } from '@/ui/tabs';
import { ToastProvider } from '@/ui/toast';

const modal: NativeStackNavigationOptions = {
  presentation: 'modal',
  ...(Platform.OS === 'ios' ? { headerLeft: () => <CloseButton /> } : {}),
};

function Routes() {
  const { ready, session, claims } = useAuth();
  const { mode } = useTheme();
  const stack = useStackOptions();
  const tabs = useTranslations('clipper.mobile.tabs');
  if (!ready) return null;
  const onboarded = !!claims?.consent_ok?.clipper;
  return (
    <ToastProvider>
      <StatusBar style={mode === 'dark' ? 'light' : 'dark'} />
      <Stack screenOptions={stack}>
        <Stack.Protected guard={!session}>
          <Stack.Screen name="login" options={{ headerShown: false }} />
        </Stack.Protected>
        <Stack.Protected guard={!!session && !onboarded}>
          <Stack.Screen name="onboarding" />
        </Stack.Protected>
        <Stack.Protected guard={!!session && onboarded}>
          {/* Judul = tab yang sedang aktif → label back iOS "‹ Dompet" di layar turunan. */}
          <Stack.Screen
            name="(tabs)"
            options={({ route }) => {
              const name = getFocusedRouteNameFromRoute(route) ?? '(campaigns)';
              return { headerShown: false, title: tabs(TAB_KEYS.find(([n]) => n === name)?.[1] ?? 'campaigns') };
            }}
          />
          <Stack.Screen name="campaign/[id]" />
          <Stack.Screen name="submit" options={modal} />
          <Stack.Screen name="filters" options={modal} />
          <Stack.Screen name="withdraw" />
          <Stack.Screen name="notifications" />
          <Stack.Screen name="share" />
          <Stack.Screen name="social" />
          <Stack.Screen name="profile" />
          <Stack.Screen name="leaderboard" />
          <Stack.Screen name="referral" />
          <Stack.Screen name="settings" />
        </Stack.Protected>
      </Stack>
      {session && onboarded ? (
        <>
          <ShareIntentGate />
          <PushGate />
          <DeviceSync />
        </>
      ) : null}
    </ToastProvider>
  );
}

function Providers() {
  const prefs = usePrefs();
  if (!prefs.ready) return null;
  return (
    <ThemeProvider pref={prefs.theme} setPref={prefs.setTheme}>
      <I18nProvider locale={prefs.locale}>
        <AuthProvider>
          <Routes />
        </AuthProvider>
      </I18nProvider>
    </ThemeProvider>
  );
}

export default function RootLayout() {
  const [fonts] = useFonts({ PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_600SemiBold, PlusJakartaSans_700Bold, PlusJakartaSans_800ExtraBold });
  if (!fonts) return null;
  return (
    <SafeAreaProvider>
      <PrefsProvider>
        <Providers />
      </PrefsProvider>
    </SafeAreaProvider>
  );
}
