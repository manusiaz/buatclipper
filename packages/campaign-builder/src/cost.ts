import { add, dec, mul, round, shift, toNumber, type Dec } from './decimal';
import { ruleRatePer1k } from './model';
import type { BuilderContext, CampaignDraft, Platform, RewardTypeOption } from './types';

export interface PoolEstimate {
  /** "± N views" per platform the pool pays on: floor(total × 1.000 ÷ Σ rate per views of the rules on that platform). */
  byPlatform: Partial<Record<Platform, number>>;
  min: number;
  max: number;
}

export interface PoolCost {
  key: string;
  reward_type_id: string;
  code: string;
  name: string;
  unit_label: string;
  decimals: number;
  /** Units (Rp for IDR, Diamonds, …). */
  total: number;
  max_per_clip: number | null;
  idr_value_per_unit: number;
  /** total × idr_value_per_unit (dasar fee & pajak, §5.2). */
  budgetIdr: number;
  /** Reward type not in context.rewardTypes → valued at 0. */
  unknownRewardType: boolean;
  est: PoolEstimate | null;
}

export interface CostSummary {
  /** Budget creator = Σ pool.total × idr_value_per_unit, round 2 (invoice subtotal). */
  budgetIdr: number;
  mgmtFee: number;
  adminFee: number;
  /** Paket managed (invoice managed_service), 0 for self-serve. */
  serviceFee: number;
  /** Pajak atas fee: campaign invoice (mgmt + admin) + managed_service invoice (service), each rounded like issue_invoice. */
  tax: number;
  total: number;
  perPool: PoolCost[];
  mgmtFeePct: number;
  adminFeePct: number;
  taxPct: number;
  /** Split of `tax` per invoice. */
  campaignTax: number;
  serviceTax: number;
}

export type CostContext = Pick<BuilderContext, 'fee' | 'taxPct' | 'rewardTypes' | 'managedServiceIdr'>;

/**
 * Pool size estimate in views, mirroring market.campaign_budget `est`: per campaign platform, rules of the pool that
 * pay per views (per_1k_views rate, tiered_cpm first tier) and apply to that platform (platform NULL or equal).
 */
export function estimatePoolViews(draft: Pick<CampaignDraft, 'platforms' | 'rules'>, poolKey: string, total: number | null): PoolEstimate | null {
  if (total == null || !(total > 0)) return null;
  const byPlatform: Partial<Record<Platform, number>> = {};
  for (const p of draft.platforms) {
    let sum = 0;
    for (const r of draft.rules) {
      if (r.pool !== poolKey || (r.platform !== null && r.platform !== p)) continue;
      const rate = ruleRatePer1k(r);
      if (rate != null && rate > 0) sum += rate;
    }
    if (sum > 0) byPlatform[p] = Math.floor((total * 1000) / sum);
  }
  const values = Object.values(byPlatform);
  if (values.length === 0) return null;
  return { byPlatform, min: Math.min(...values), max: Math.max(...values) };
}

/** Views that a per-clip cap equals at a rate per 1.000 views (cap × 1.000 ÷ rate). */
export function capInViews(maxPerClip: number | null, ratePer1k: number | null): number | null {
  if (maxPerClip == null || ratePer1k == null || !(ratePer1k > 0) || !(maxPerClip > 0)) return null;
  return Math.floor((maxPerClip * 1000) / ratePer1k);
}

function pct(n: number): Dec {
  return shift(dec(n), 2);
}

/**
 * Cost breakdown shown before "Ajukan", mirroring finance.issue_invoice exactly:
 *   sub = round(Σ total × idr_value_per_unit, 2); mgmt = round(sub × mgmt% / 100, 2); admin = round(sub × admin% / 100, 2);
 *   tax = round((mgmt + admin + service) × tax% / 100, 2) per invoice; total = sub + mgmt + admin + service + tax.
 * Managed package = separate managed_service invoice (subtotal 0, service_fee = managed_service_idr) with its own tax.
 * Fee: admin override (draft.fee = set) wins over ctx.fee (effective rule campaign → org → global).
 */
export function costSummary(draft: CampaignDraft, ctx: CostContext): CostSummary {
  const fee = draft.fee.mode === 'set' ? { mgmt_fee_pct: draft.fee.mgmt_fee_pct, admin_fee_pct: draft.fee.admin_fee_pct } : ctx.fee;
  const perPool: PoolCost[] = draft.pools.map((pool) => {
    const rt: RewardTypeOption | undefined = ctx.rewardTypes.find((r) => r.id === pool.reward_type_id);
    const total = pool.total ?? 0;
    const value = rt?.idr_value_per_unit ?? 0;
    return {
      key: pool.key,
      reward_type_id: pool.reward_type_id,
      code: rt?.code ?? '',
      name: rt?.name ?? '',
      unit_label: rt?.unit_label ?? '',
      decimals: rt?.decimals ?? 0,
      total,
      max_per_clip: pool.max_per_clip,
      idr_value_per_unit: value,
      budgetIdr: toNumber(round(mul(dec(total), dec(value)), 2)),
      unknownRewardType: !rt,
      est: estimatePoolViews(draft, pool.key, pool.total),
    };
  });

  const raw = add(...draft.pools.map((pool) => mul(dec(pool.total ?? 0), dec(ctx.rewardTypes.find((r) => r.id === pool.reward_type_id)?.idr_value_per_unit ?? 0))));
  const sub = round(raw, 2);
  const mgmt = round(mul(sub, pct(fee.mgmt_fee_pct)), 2);
  const adm = round(mul(sub, pct(fee.admin_fee_pct)), 2);
  const taxRate = pct(ctx.taxPct);
  const campaignTax = round(mul(add(mgmt, adm), taxRate), 2);
  const svc = draft.service_mode === 'managed' ? round(dec(ctx.managedServiceIdr), 2) : dec(0);
  const serviceTax = round(mul(svc, taxRate), 2);
  const tax = add(campaignTax, serviceTax);
  const total = add(sub, mgmt, adm, svc, tax);

  return {
    budgetIdr: toNumber(sub),
    mgmtFee: toNumber(mgmt),
    adminFee: toNumber(adm),
    serviceFee: toNumber(svc),
    tax: toNumber(tax),
    total: toNumber(total),
    perPool,
    mgmtFeePct: fee.mgmt_fee_pct,
    adminFeePct: fee.admin_fee_pct,
    taxPct: ctx.taxPct,
    campaignTax: toNumber(campaignTax),
    serviceTax: toNumber(serviceTax),
  };
}
