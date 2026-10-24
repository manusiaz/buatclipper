import type { HTMLAttributes } from 'react';
import { cn } from '../lib/cn';
import { formatCompact, formatIDR, formatNumber, type UiLocale } from '../lib/format';

export interface MoneyProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'children'> {
  /** Amount in the unit's base value (IDR rupiah, points, diamonds…). */
  value: number;
  /** "IDR" (default) → "Rp1.500.000"; anything else → "1.500 <unitLabel>". */
  unit?: 'IDR' | (string & {});
  /** Label for non-IDR units, e.g. "poin", "diamond", "views". */
  unitLabel?: string;
  /** "Rp1,5 jt". */
  compact?: boolean;
  /** Prefix "+" for positive values (ledger). Negative values always get "−". */
  signed?: boolean;
  /** Colour by sign (+ success, − danger). */
  colored?: boolean;
  locale?: UiLocale;
}

/** Formatted money/units with tabular figures (DS 11: "Rp" glued, units always written). Server-compatible. */
export function Money({ value, unit = 'IDR', unitLabel, compact, signed, colored, locale = 'id', className, ...rest }: MoneyProps) {
  let text: string;
  if (unit === 'IDR') text = formatIDR(value, { locale, compact, signed });
  else {
    const n = compact ? formatCompact(Math.abs(value), locale) : formatNumber(Math.abs(value), locale);
    const sign = value < 0 ? '−' : signed && value > 0 ? '+' : '';
    text = `${sign}${n}${unitLabel ? ` ${unitLabel}` : ''}`;
  }
  return (
    <span
      className={cn('tnum whitespace-nowrap', colored && value > 0 && 'text-success-fg', colored && value < 0 && 'text-danger-fg', className)}
      {...rest}
    >
      {text}
    </span>
  );
}
