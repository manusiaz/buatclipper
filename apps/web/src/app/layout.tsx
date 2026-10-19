import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import { headers } from 'next/headers';
import { NextIntlClientProvider } from 'next-intl';
import { getLocale } from 'next-intl/server';
import { ThemeProvider, Toaster } from '@clipper/ui';
import './globals.css';

export const metadata: Metadata = {
  title: { default: 'Clipper — dibayar per views', template: '%s · Clipper' },
};

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#F6F8FC' },
    { media: '(prefers-color-scheme: dark)', color: '#0A1226' },
  ],
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const nonce = (await headers()).get('x-nonce') ?? undefined;
  return (
    <html lang={await getLocale()} suppressHydrationWarning>
      <body className="bg-page min-h-dvh font-sans text-ink antialiased">
        <NextIntlClientProvider>
          <ThemeProvider nonce={nonce}>
            {children}
            <Toaster />
          </ThemeProvider>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
