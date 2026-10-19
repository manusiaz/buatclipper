import { formatDateTime, formatIDR, formatNumber, type UiLocale } from '@clipper/ui';

/** Jumlah dalam unit reward type: Rupiah → "Rp2.000", lainnya → "8 Diamonds". */
export function formatAmount(value: number, unit: { code: string | null; unit_label: string | null; decimals: number | null }, locale: UiLocale) {
  if (unit.code === 'IDR') return formatIDR(value, { locale, fractionDigits: Number.isInteger(value) ? 0 : 2 });
  const n = formatNumber(value, locale, { maximumFractionDigits: unit.decimals ?? 2 });
  return `${n} ${unit.unit_label ?? unit.code ?? ''}`.trim();
}

/** Tanggal absolut WIB untuk timeline (DS: halaman detail pakai tanggal absolut). */
export const formatWib = (value: string, locale: UiLocale) =>
  `${formatDateTime(value, locale, { dateStyle: 'long', timeStyle: 'short' })} WIB`;
