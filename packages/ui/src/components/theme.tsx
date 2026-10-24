'use client';

import { ThemeProvider as NextThemesProvider, useTheme } from 'next-themes';
import { useEffect, useState, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { IconButton } from './button';
import { Icon, type IconName } from './icon';

export { useTheme };

export interface ThemeProviderProps {
  children: ReactNode;
  /** CSP nonce for the inline theme script (pass the per-request nonce from proxy.ts headers). */
  nonce?: string;
  /** Default "system". */
  defaultTheme?: 'light' | 'dark' | 'system';
  /** Force a theme (e.g. admin print views). */
  forcedTheme?: 'light' | 'dark';
  storageKey?: string;
}

/** next-themes with class strategy (`.dark` on <html>), system default, no transition flash. */
export function ThemeProvider({ children, nonce, defaultTheme = 'system', forcedTheme, storageKey = 'clipper-theme' }: ThemeProviderProps) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme={defaultTheme}
      enableSystem
      disableTransitionOnChange
      forcedTheme={forcedTheme}
      storageKey={storageKey}
      nonce={nonce}
    >
      {children}
    </NextThemesProvider>
  );
}

export interface ThemeToggleProps {
  /** `icon` = single button toggling light/dark; `segmented` = Terang / Sistem / Gelap. */
  variant?: 'icon' | 'segmented';
  labels?: { light?: string; dark?: string; system?: string; toggle?: string };
  className?: string;
}

/** Theme switcher. Renders a neutral placeholder until mounted (avoids hydration mismatch). */
export function ThemeToggle({ variant = 'icon', labels, className }: ThemeToggleProps) {
  const { theme, resolvedTheme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const t = { light: 'Terang', dark: 'Gelap', system: 'Sistem', toggle: 'Ganti tema', ...labels };

  if (variant === 'icon') {
    const isDark = mounted && resolvedTheme === 'dark';
    return (
      <IconButton
        icon={isDark ? 'light_mode' : 'dark_mode'}
        label={mounted ? (isDark ? t.light : t.dark) : t.toggle}
        onClick={() => setTheme(isDark ? 'light' : 'dark')}
        className={className}
      />
    );
  }
  const opts: Array<{ v: 'light' | 'system' | 'dark'; icon: IconName; label: string }> = [
    { v: 'light', icon: 'light_mode', label: t.light },
    { v: 'system', icon: 'contrast', label: t.system },
    { v: 'dark', icon: 'dark_mode', label: t.dark },
  ];
  return (
    <div role="radiogroup" aria-label={t.toggle} className={cn('inline-flex gap-1 rounded-control bg-subtle p-1', className)}>
      {opts.map((o) => {
        const active = mounted && theme === o.v;
        return (
          <button
            key={o.v}
            type="button"
            role="radio"
            aria-checked={active}
            onClick={() => setTheme(o.v)}
            className={cn(
              'inline-flex h-9 items-center gap-1.5 rounded-[9px] px-3 text-sm font-semibold text-muted transition-colors duration-120 hover:text-ink focus-ring',
              active && 'bg-surface font-bold text-ink shadow-hairline',
            )}
          >
            <Icon name={o.icon} size={18} filled={active} />
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
