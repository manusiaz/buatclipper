'use client';

import { useTranslations } from 'next-intl';
import { errorKeys } from './errors';

/** Kode error dari action → teks terjemahan (accounts.errors dulu, lalu errors bersama). */
export function useErrorText(): (code: string | null | undefined) => string {
  const t = useTranslations();
  return (code) => {
    const { keys, param } = errorKeys(code);
    return t(keys.find((k) => t.has(k)) ?? 'errors.generic', { param });
  };
}
