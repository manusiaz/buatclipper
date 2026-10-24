import { useLocale, useTranslations } from 'next-intl';
import { formatIDR, formatNumber } from '@clipper/ui';

/**
 * Loosely typed translator for the `builder` namespace (messages/{id,en}/builder.json). Keys are built from data
 * (step ids, rule kinds, error codes), so the builder does not depend on an app's typed AppConfig.Messages.
 */
export type Translate = (key: string, values?: Record<string, string | number>) => string;

export function useBuilderT(): Translate {
  return useTranslations('builder') as unknown as Translate;
}

export type Locale = 'id' | 'en';

export function useUiLocale(): Locale {
  return useLocale() === 'en' ? 'en' : 'id';
}

/** Rupiah with cents only when present ("Rp12.220.000", "Rp1.234,56"). */
export function idr(value: number, locale: Locale): string {
  return formatIDR(value, { locale, fractionDigits: Number.isInteger(value) ? 0 : 2 });
}

/** Amount in a reward unit: IDR → "Rp20.000"; others → "8 Diamonds". */
export function units(value: number, rt: { code: string; unit_label: string; decimals: number } | undefined, locale: Locale): string {
  if (!rt || rt.code === 'IDR') return idr(value, locale);
  return `${formatNumber(value, locale, { maximumFractionDigits: Math.max(rt.decimals, 2) })} ${rt.unit_label}`;
}

export function num(value: number, locale: Locale): string {
  return formatNumber(value, locale);
}
