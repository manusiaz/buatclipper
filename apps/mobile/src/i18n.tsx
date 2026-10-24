// Teks = JSON yang sama dengan app Next (@clipper/i18n), lewat use-intl (inti next-intl). Bahasa: pilihan user → perangkat.
import { useCallback } from 'react';
import { IntlProvider, useTranslations } from 'use-intl';
import { parseDbError } from '@clipper/i18n/core';
import { errorKey, isPlatform } from '@clipper/clipper-lib/pure';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import idAuth from '@clipper/i18n/messages/id/auth';
import idClipper from '@clipper/i18n/messages/id/clipper';
import idCommon from '@clipper/i18n/messages/id/common';
import idErrors from '@clipper/i18n/messages/id/errors';
import idNotifications from '@clipper/i18n/messages/id/notifications';
import enAuth from '@clipper/i18n/messages/en/auth';
import enClipper from '@clipper/i18n/messages/en/clipper';
import enCommon from '@clipper/i18n/messages/en/common';
import enErrors from '@clipper/i18n/messages/en/errors';
import enNotifications from '@clipper/i18n/messages/en/notifications';
import type { ReactNode } from 'react';

export type Locale = 'id' | 'en';

const MESSAGES = {
  id: { auth: idAuth, clipper: idClipper, common: idCommon, errors: idErrors, notifications: idNotifications },
  en: { auth: enAuth, clipper: enClipper, common: enCommon, errors: enErrors, notifications: enNotifications },
};

export function I18nProvider({ locale, children }: { locale: Locale; children: ReactNode }) {
  return (
    <IntlProvider locale={locale} messages={MESSAGES[locale]} timeZone="Asia/Jakarta" onError={() => {}}>
      {children}
    </IntlProvider>
  );
}

/** Kode error RPC/Edge Function → pesan (errors, lalu clipper.errors, lalu generic) — sama dengan errorText app Next. */
export function useErrorText() {
  const tErr = useTranslations('errors');
  const tApp = useTranslations('clipper.errors');
  return useCallback(
    (raw: string | null | undefined, detail?: unknown) => {
      const { key, param } = errorKey(raw, detail, (p) => (isPlatform(p) ? platformLabels[p as Platform] : p));
      if (tErr.has(key)) return tErr(key, { param });
      if (tApp.has(key)) return tApp(key, { param });
      return tErr('generic');
    },
    [tErr, tApp],
  );
}

export { parseDbError };
