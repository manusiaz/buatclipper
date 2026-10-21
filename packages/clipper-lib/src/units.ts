// Format nominal per reward type: IDR → "Rp1.500", lainnya → "8 Diamonds" (desimal sesuai reward type).
import { formatIDR, formatNumber, type UiLocale } from '@clipper/ui/format';
import { num } from './pure';

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

export interface EarningRow {
  submission_id: string | null;
  pool_id: string | null;
  amount: number | string | null;
  released_at: string | null;
}

/** Earning per submisi dikelompokkan per reward type (pool → unit): Rp dan poin tidak pernah dijumlah jadi satu. */
export function earningsBySubmission<U extends { id: string }>(rows: EarningRow[], poolUnit: Map<string | null, U | undefined>) {
  const out = new Map<string, Map<string, { unit: U | undefined; pending: number; released: number }>>();
  for (const e of rows) {
    if (!e.submission_id) continue;
    const amount = num(e.amount);
    const unit = poolUnit.get(e.pool_id);
    const key = unit?.id ?? e.pool_id ?? '';
    const per = out.get(e.submission_id) ?? new Map();
    const cur = per.get(key) ?? { unit, pending: 0, released: 0 };
    if (e.released_at) cur.released += amount;
    else cur.pending += amount;
    per.set(key, cur);
    out.set(e.submission_id, per);
  }
  return (sid: string) => [...(out.get(sid)?.values() ?? [])].filter((x) => x.pending > 0 || x.released > 0);
}
