import type { CampaignRate, Platform } from '@clipper/ui';
import { num } from './settings';

/** Rate rule aktif yang sudah digabung dengan reward type-nya (dari api.list_campaigns `rates` atau view publik). */
export interface Rule {
  kind: string;
  platform: Platform | null;
  params: unknown;
  code: string | null;
  unit_label: string | null;
  decimals: number | null;
  pool_id: string | null;
}

export type ParsedRule =
  | { kind: 'per_1k_views'; rate: number }
  | { kind: 'flat_per_post'; amount: number }
  | { kind: 'milestone_bonus'; threshold: number; amount: number }
  | { kind: 'tiered_cpm'; tiers: Array<{ from: number; to: number | null; rate: number }> };

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

/** Parameter rule (§10.2) → bentuk bertipe; parameter rusak → null (tidak ditampilkan). */
export function parseRule(kind: string, params: unknown): ParsedRule | null {
  const p = obj(params);
  switch (kind) {
    case 'per_1k_views': {
      const rate = num(p.rate);
      return rate != null ? { kind, rate } : null;
    }
    case 'flat_per_post': {
      const amount = num(p.amount);
      return amount != null ? { kind, amount } : null;
    }
    case 'milestone_bonus': {
      const threshold = num(p.threshold);
      const amount = num(p.amount);
      return threshold != null && amount != null ? { kind, threshold, amount } : null;
    }
    case 'tiered_cpm': {
      const tiers = (Array.isArray(p.tiers) ? p.tiers : [])
        .map((t) => {
          const o = obj(t);
          const rate = num(o.rate);
          return rate != null ? { from: num(o.from) ?? 0, to: num(o.to), rate } : null;
        })
        .filter((t): t is { from: number; to: number | null; rate: number } => t !== null);
      return tiers.length ? { kind, tiers } : null;
    }
    default:
      return null;
  }
}

/** Rate per 1.000 views sebuah rule (salinan market.rule_rate: tiered_cpm = tier pertama). */
export function ruleRate(kind: string, params: unknown): number | null {
  const r = parseRule(kind, params);
  if (r?.kind === 'per_1k_views') return r.rate;
  if (r?.kind === 'tiered_cpm') return r.tiers[0]?.rate ?? null;
  return null;
}

const applies = (r: Rule, p: Platform) => r.platform === null || r.platform === p;

/** Rate Rupiah per 1.000 views per platform (rule bertumpuk dijumlah, sama dengan urutan sort=rate di list_campaigns). */
export function idrRates(rules: readonly Rule[], platforms: readonly Platform[]): CampaignRate[] {
  return platforms
    .map((platform) => ({
      platform,
      ratePer1k: rules
        .filter((r) => r.code === 'IDR' && applies(r, platform))
        .reduce((sum, r) => sum + (ruleRate(r.kind, r.params) ?? 0), 0),
    }))
    .filter((r) => r.ratePer1k > 0);
}

/** `rates` jsonb dari api.list_campaigns → Rule[]. */
export function rulesFromJson(json: unknown): Rule[] {
  if (!Array.isArray(json)) return [];
  return json.map((x) => {
    const o = obj(x);
    return {
      kind: typeof o.kind === 'string' ? o.kind : '',
      platform: typeof o.platform === 'string' ? (o.platform as Platform) : null,
      params: o.params,
      code: typeof o.code === 'string' ? o.code : null,
      unit_label: typeof o.unit_label === 'string' ? o.unit_label : null,
      decimals: num(o.decimals),
      pool_id: typeof o.pool_id === 'string' ? o.pool_id : null,
    };
  });
}

/** est_remaining_views {platform: views} → views terbanyak (pool yang paling lama habis), atau null. */
export function maxViews(json: unknown): number | null {
  const vals = Object.values(obj(json)).map(num).filter((v): v is number => v != null);
  return vals.length ? Math.max(...vals) : null;
}

/** Salinan est_remaining_views market.campaign_budget untuk halaman publik (view rate_rules + reward_pools). */
export function estRemainingViews(
  pools: ReadonlyArray<{ id: string; remaining: number }>,
  rules: readonly Rule[],
  platforms: readonly Platform[],
): number | null {
  let best: number | null = null;
  for (const pool of pools) {
    for (const p of platforms) {
      const sum = rules
        .filter((r) => r.pool_id === pool.id && applies(r, p))
        .map((r) => ruleRate(r.kind, r.params) ?? 0)
        .filter((v) => v > 0)
        .reduce((a, b) => a + b, 0);
      if (sum > 0) {
        const views = Math.floor((Math.max(pool.remaining, 0) * 1000) / sum);
        best = best == null ? views : Math.max(best, views);
      }
    }
  }
  return best;
}

/** Platform dengan set rule yang sama digabung, supaya "semua platform" tidak diulang per platform. */
export function rateGroups(rules: readonly Rule[], platforms: readonly Platform[]): Array<{ platforms: Platform[]; rules: Rule[] }> {
  const groups: Array<{ key: string; platforms: Platform[]; rules: Rule[] }> = [];
  for (const p of platforms) {
    const own = rules.filter((r) => applies(r, p));
    if (!own.length) continue;
    const key = own.map((r) => rules.indexOf(r)).join(',');
    const g = groups.find((x) => x.key === key);
    if (g) g.platforms.push(p);
    else groups.push({ key, platforms: [p], rules: own });
  }
  return groups.map(({ platforms: ps, rules: rs }) => ({ platforms: ps, rules: rs }));
}
