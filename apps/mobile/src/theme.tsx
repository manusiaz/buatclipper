// Tema native = token DS web (tokens.gen.ts dari packages/ui/src/styles.css). Mode mengikuti sistem atau pilihan user.
import { createContext, useContext, useMemo, type ReactNode } from 'react';
import { useColorScheme } from 'react-native';
import { tokens } from './tokens.gen';

export type ColorMode = 'light' | 'dark';
type Colors = { [K in keyof (typeof tokens)['light']]: string };
export type TextVariant = keyof typeof tokens.text;

// Android tidak memilih varian berdasarkan fontWeight untuk font kustom → weight dipetakan ke nama font yang dimuat.
const FONT: Record<string, string> = {
  '400': 'PlusJakartaSans_400Regular',
  '500': 'PlusJakartaSans_500Medium',
  '600': 'PlusJakartaSans_600SemiBold',
  '700': 'PlusJakartaSans_700Bold',
  '800': 'PlusJakartaSans_800ExtraBold',
};
export const fontFor = (weight: string | undefined) => FONT[weight ?? '400'] ?? FONT['400']!;

export interface Theme {
  mode: ColorMode;
  c: Colors;
  radius: (typeof tokens)['radius'];
  text: (typeof tokens)['text'];
}

const ThemeContext = createContext<{ pref: ColorMode | 'system'; setPref: (p: ColorMode | 'system') => void } | null>(null);

export function ThemeProvider({ pref, setPref, children }: { pref: ColorMode | 'system'; setPref: (p: ColorMode | 'system') => void; children: ReactNode }) {
  const value = useMemo(() => ({ pref, setPref }), [pref, setPref]);
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useThemePref() {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('ThemeProvider belum dipasang');
  return ctx;
}

export function useTheme(): Theme {
  const system = useColorScheme();
  const pref = useContext(ThemeContext)?.pref ?? 'system';
  const mode: ColorMode = pref === 'system' ? (system === 'dark' ? 'dark' : 'light') : pref;
  return useMemo(() => ({ mode, c: tokens[mode] as Colors, radius: tokens.radius, text: tokens.text }), [mode]);
}

/** Bayangan kartu DS (surface-card) versi native. */
export const cardShadow = {
  shadowColor: '#10286e',
  shadowOpacity: 0.12,
  shadowRadius: 18,
  shadowOffset: { width: 0, height: 10 },
  elevation: 3,
} as const;
