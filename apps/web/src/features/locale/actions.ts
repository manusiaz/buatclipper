'use server';

import { cookies } from 'next/headers';
import { LOCALE_COOKIE, locales, type Locale } from '@clipper/i18n';

/** F-C18: cookie NEXT_LOCALE berlaku di semua subdomain (Domain = NEXT_PUBLIC_COOKIE_DOMAIN), sama dengan app clipper. */
export async function setLocale(locale: Locale): Promise<void> {
  if (!(locales as readonly string[]).includes(locale)) return;
  (await cookies()).set(LOCALE_COOKIE, locale, {
    domain: process.env.NEXT_PUBLIC_COOKIE_DOMAIN || undefined,
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
    sameSite: 'lax',
    secure: (process.env.NEXT_PUBLIC_WEB_URL ?? '').startsWith('https://'),
  });
}
