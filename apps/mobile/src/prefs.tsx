// Bahasa & tema pilihan user (AsyncStorage — bukan data sensitif). Default: bahasa perangkat (id kecuali en), tema sistem.
import AsyncStorage from '@react-native-async-storage/async-storage';
import { getLocales } from 'expo-localization';
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Locale } from './i18n';
import type { ColorMode } from './theme';

type ThemePref = ColorMode | 'system';
interface Prefs {
  ready: boolean;
  locale: Locale;
  theme: ThemePref;
  setLocale: (l: Locale) => void;
  setTheme: (t: ThemePref) => void;
}

const PrefsContext = createContext<Prefs | null>(null);
const deviceLocale = (): Locale => (getLocales()[0]?.languageCode === 'en' ? 'en' : 'id');

export function PrefsProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [locale, setLocaleState] = useState<Locale>(deviceLocale);
  const [theme, setThemeState] = useState<ThemePref>('system');
  useEffect(() => {
    AsyncStorage.multiGet(['clipper.locale', 'clipper.theme'])
      .then((pairs) => {
        const l = pairs[0]?.[1];
        const t = pairs[1]?.[1];
        if (l === 'id' || l === 'en') setLocaleState(l);
        if (t === 'light' || t === 'dark' || t === 'system') setThemeState(t);
      })
      .finally(() => setReady(true));
  }, []);
  const setLocale = useCallback((l: Locale) => {
    setLocaleState(l);
    void AsyncStorage.setItem('clipper.locale', l);
  }, []);
  const setTheme = useCallback((t: ThemePref) => {
    setThemeState(t);
    void AsyncStorage.setItem('clipper.theme', t);
  }, []);
  return <PrefsContext.Provider value={{ ready, locale, theme, setLocale, setTheme }}>{children}</PrefsContext.Provider>;
}

export function usePrefs(): Prefs {
  const ctx = useContext(PrefsContext);
  if (!ctx) throw new Error('PrefsProvider belum dipasang');
  return ctx;
}
