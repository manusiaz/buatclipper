'use client';

import { useTranslations } from 'next-intl';
import { parseDbError } from '@clipper/i18n';

type T = ReturnType<typeof useTranslations>;

function message(t: T, key: string, param: string): string | null {
  return t.has(key) && typeof t.raw(key) === 'string' ? t(key, { param }) : null;
}

/** Kode error action (lib/errors.ts, Edge Function) → teks: admin.errors dulu, lalu namespace errors bersama. */
export function useErrorText() {
  const shared = useTranslations('errors');
  const admin = useTranslations('admin.errors');
  return (code: string): string => {
    const { key, param } = parseDbError(code);
    return (
      message(admin, key, param) ??
      message(shared, key, param) ??
      (key.startsWith('not_found') ? message(admin, 'not_found.any', param) : null) ??
      shared('generic')
    );
  };
}
