'use client';

import { useTranslations } from 'next-intl';
import { parseDbError } from '@clipper/i18n';

/** Kode error fungsi api → teks: brand.errors.field.<param> (invalid:<field>), lalu namespace errors bersama. */
export function useErrorText(): (code: string | null | undefined) => string {
  const t = useTranslations('errors');
  const tb = useTranslations('brand.errors');
  return (code) => {
    const { key, param } = parseDbError(code);
    if (key === 'invalid' && param && tb.has(`field.${param}`)) return tb(`field.${param}`);
    if (tb.has(`code.${key}`)) return tb(`code.${key}`, { param });
    if (t.has(key)) return t(key, { param });
    return t('generic');
  };
}
