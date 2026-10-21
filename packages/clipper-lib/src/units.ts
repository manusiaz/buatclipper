// Format nominal per reward type: IDR → "Rp1.500", lainnya → "8 Diamonds" (desimal sesuai reward type).
import { formatIDR, formatNumber, type UiLocale } from '@clipper/ui/format';

export interface UnitLike {
  code: string;
  unit_label: string;
  decimals?: number;
}

export function formatAmount(value: number, unit: UnitLike | null | undefined, locale: UiLocale, signed = false): string {
  if (!unit || unit.code === 'IDR') return formatIDR(value, { locale, signed });
  const sign = value < 0 ? '−' : signed && value > 0 ? '+' : '';
  const n = formatNumber(Math.abs(value), locale, { maximumFractionDigits: unit.decimals ?? 0 });
  return `${sign}${n}${unit.unit_label ? ` ${unit.unit_label}` : ''}`;
}
