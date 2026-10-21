// Root app native: font DS, preferensi, i18n, tema, sesi, share sheet; gate rute sama dengan requireClipper web.
import { PlusJakartaSans_400Regular, PlusJakartaSans_500Medium, PlusJakartaSans_600SemiBold, PlusJakartaSans_700Bold, PlusJakartaSans_800ExtraBold, useFonts } from '@expo-google-fonts/plus-jakarta-sans';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { AuthProvider, useAuth } from '@/auth';
import { I18nProvider } from '@/i18n';
import { PrefsProvider, usePrefs } from '@/prefs';
import { PushGate } from '@/push-gate';
import { ShareIntentGate } from '@/share-intent';
import { ThemeProvider, useTheme } from '@/theme';

function Routes() {
  const { ready, session, claims } = useAuth();
  const { c, mode } = useTheme();
  if (!ready) return null;
  const onboarded = !!claims?.consent_ok?.clipper;
  return (
    <>
      <StatusBar style={mode === 'dark' ? 'light' : 'dark'} />
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: c.canvas } }}>
        <Stack.Protected guard={!session}>
          <Stack.Screen name="login" />
        </Stack.Protected>
        <Stack.Protected guard={!!session && !onboarded}>
          <Stack.Screen name="onboarding" />
        </Stack.Protected>
        <Stack.Protected guard={!!session && onboarded}>
          <Stack.Screen name="(tabs)" />
          <Stack.Screen name="campaign/[id]" />
          <Stack.Screen name="submit" options={{ presentation: 'modal' }} />
          <Stack.Screen name="notifications" />
          <Stack.Screen name="share" />
          <Stack.Screen name="account" />
        </Stack.Protected>
      </Stack>
      {session && onboarded ? (
        <>
          <ShareIntentGate />
          <PushGate />
        </>
      ) : null}
    </>
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
