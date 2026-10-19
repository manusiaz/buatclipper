import { formatIDR, formatNumber, type UiLocale } from '@clipper/ui';

export interface RuleJson {
  rule_id?: string;
  kind: string;
  platform: string | null;
  code: string;
  unit_label: string;
  params: { rate?: number; amount?: number; threshold?: number; tiers?: { from: number; to: number | null; rate: number }[] } | null;
}

export interface PoolJson {
  pool_id: string;
  code: string;
  unit_label: string;
  total: number | string;
  remaining?: number | string;
  max_per_clip: number | string | null;
}

export const amount = (v: number | string | null | undefined, code: string, unit: string, loc: UiLocale) =>
  v == null ? '—' : code === 'IDR' ? formatIDR(Number(v), { locale: loc }) : `${formatNumber(Number(v), loc, { maximumFractionDigits: 2 })} ${unit}`;

/** Ringkasan params rate rule (§10.2) dalam satu baris. */
export function ruleParams(r: RuleJson, loc: UiLocale): string {
  const p = r.params ?? {};
  const a = (v: number | undefined) => amount(v, r.code, r.unit_label, loc);
  switch (r.kind) {
    case 'per_1k_views':
      return `${a(p.rate)} / 1K views`;
    case 'flat_per_post':
      return `${a(p.amount)} / post`;
    case 'milestone_bonus':
      return `${a(p.amount)} @ ${formatNumber(Number(p.threshold ?? 0), loc)} views`;
    case 'tiered_cpm':
      return (p.tiers ?? [])
        .map((t) => `${formatNumber(Number(t.from), loc)}–${t.to == null ? '∞' : formatNumber(Number(t.to), loc)}: ${a(t.rate)}/1K`)
        .join(' · ');
    default:
      return JSON.stringify(p);
  }
}
