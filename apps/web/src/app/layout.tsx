import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { headers } from 'next/headers';
import { NextIntlClientProvider } from 'next-intl';
import { getLocale, getMessages, getTranslations } from 'next-intl/server';
import { hosts } from '@clipper/auth';
import { ThemeProvider } from '@clipper/ui';
import { SiteShell } from '@/components/site-shell';
import './globals.css';

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations('web.meta');
  return {
    metadataBase: new URL(hosts.web),
    title: { default: t('title'), template: '%s · Clipper' },
    description: t('description'),
    applicationName: 'Clipper',
    openGraph: { type: 'website', siteName: 'Clipper', title: t('title'), description: t('description') },
    twitter: { card: 'summary_large_image' },
  };
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#F6F8FC' },
    { media: '(prefers-color-scheme: dark)', color: '#0A1226' },
  ],
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const [nonce, locale, messages] = await Promise.all([
    headers().then((h) => h.get('x-nonce') ?? undefined),
    getLocale(),
    getMessages(),
  ]);
  return (
    <html lang={locale} suppressHydrationWarning>
      <body className="bg-page min-h-dvh font-sans text-ink antialiased">
        {/* Halaman publik hampir semuanya server component: client cukup dapat namespace common (error boundary). */}
        <NextIntlClientProvider messages={{ common: messages.common }}>
          <ThemeProvider nonce={nonce}>
            <SiteShell>{children}</SiteShell>
          </ThemeProvider>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
