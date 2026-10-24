// Bentuk JSON api.campaign_stats (market.campaign_report + campaign_budget + campaign_projection).
type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const n = (v: unknown): number | null => {
  const x = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(x) ? x : null;
};
const str = (v: unknown): string | null => (typeof v === 'string' ? v : null);
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isObj) : []);
const numMap = (v: unknown): Record<string, number> =>
  isObj(v) ? Object.fromEntries(Object.entries(v).flatMap(([k, x]) => (n(x) == null ? [] : [[k, n(x)!]]))) : {};

export interface PoolStat {
  poolId: string;
  code: string;
  unitLabel: string;
  decimals: number;
  idrPerUnit: number;
  total: number;
  allocated: number;
  remaining: number;
  maxPerClip: number | null;
  estRemainingViews: Record<string, number>;
}

export interface CampaignStats {
  viewsValid: number;
  clips: number;
  clippers: number;
  byPlatform: Record<string, number>;
  topClips: { url: string; platform: string; views: number }[];
  pools: PoolStat[];
  budgetIdr: number;
  spentIdr: number;
  remainingIdr: number;
  utilizationPct: number | null;
  ecpmIdr: number | null;
  estRemainingViews: Record<string, number>;
  projection: {
    dailySpendIdr: number | null;
    projectedUtilizationPct: number | null;
    projectedExhaustAt: string | null;
    horizonAt: string | null;
    exhaustsBeforeHorizon: boolean | null;
    elapsedDays: number | null;
  };
  daily: { day: string; views: number }[];
}

export function parseStats(raw: unknown): CampaignStats {
  const s = isObj(raw) ? raw : {};
  const p = isObj(s.projection) ? s.projection : {};
  return {
    viewsValid: n(s.views_valid) ?? 0,
    clips: n(s.clips) ?? 0,
    clippers: n(s.clippers) ?? 0,
    byPlatform: numMap(s.by_platform),
    topClips: arr(s.top_clips).flatMap((c) => (str(c.url) ? [{ url: str(c.url)!, platform: str(c.platform) ?? '', views: n(c.views) ?? 0 }] : [])),
    pools: arr(s.pools).map((x) => ({
      poolId: str(x.pool_id) ?? '',
      code: str(x.code) ?? '',
      unitLabel: str(x.unit_label) ?? '',
      decimals: n(x.decimals) ?? 0,
      idrPerUnit: n(x.idr_value_per_unit) ?? 0,
      total: n(x.total) ?? 0,
      allocated: n(x.allocated) ?? 0,
      remaining: n(x.remaining) ?? 0,
      maxPerClip: n(x.max_per_clip),
      estRemainingViews: numMap(x.est_remaining_views),
    })),
    budgetIdr: n(s.budget_idr) ?? 0,
    spentIdr: n(s.spent_idr) ?? 0,
    remainingIdr: n(s.remaining_idr) ?? 0,
    utilizationPct: n(s.utilization_pct),
    ecpmIdr: n(s.ecpm_idr),
    estRemainingViews: numMap(s.est_remaining_views),
    projection: {
      dailySpendIdr: n(p.daily_spend_idr),
      projectedUtilizationPct: n(p.projected_utilization_pct),
      projectedExhaustAt: str(p.projected_exhaust_at),
      horizonAt: str(p.horizon_at),
      exhaustsBeforeHorizon: typeof p.exhausts_before_horizon === 'boolean' ? p.exhausts_before_horizon : null,
      elapsedDays: n(p.elapsed_days),
    },
    daily: arr(s.daily).flatMap((d) => (str(d.day) ? [{ day: str(d.day)!, views: n(d.views) ?? 0 }] : [])),
  };
}

/** Saran F-B08 saat proyeksi pemakaian < 50% (job budget-alerts memakai ambang yang sama). */
export function lowProjection(stats: CampaignStats, status: string): boolean {
  const pct = stats.projection.projectedUtilizationPct;
  return status === 'live' && pct != null && pct < 50 && (stats.projection.elapsedDays ?? 0) >= 2;
}
