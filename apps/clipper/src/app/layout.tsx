import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { headers } from 'next/headers';
import { NextIntlClientProvider } from 'next-intl';
import { getLocale } from 'next-intl/server';
import { ThemeProvider, Toaster } from '@clipper/ui';
import { AppChrome } from '@/features/shell/app-chrome';
import { loadChrome } from '@/features/shell/chrome';
import { ServiceWorker } from '@/features/pwa/service-worker';
import './globals.css';

export const metadata: Metadata = {
  title: { default: 'Clipper', template: '%s · Clipper' },
  applicationName: 'Clipper',
  appleWebApp: { capable: true, title: 'Clipper', statusBarStyle: 'default' },
  formatDetection: { telephone: false },
  icons: {
    icon: [{ url: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' }],
    apple: [{ url: '/icons/apple-touch-icon.png', sizes: '180x180' }],
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#F6F8FC' },
    { media: '(prefers-color-scheme: dark)', color: '#0A1226' },
  ],
  viewportFit: 'cover',
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const nonce = (await headers()).get('x-nonce') ?? undefined;
  const [locale, chrome] = await Promise.all([getLocale(), loadChrome()]);
  return (
    <html lang={locale} suppressHydrationWarning>
      <body className="bg-page min-h-dvh font-sans text-ink antialiased">
        <NextIntlClientProvider>
          <ThemeProvider nonce={nonce}>
            <AppChrome data={chrome}>{children}</AppChrome>
            <Toaster />
            <ServiceWorker />
          </ThemeProvider>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
