import { DEFAULTS, EDITABLE_STATUSES, PLATFORMS } from './constants';
import type { BuilderContext, CampaignDraft, Platform, PoolDraft, RewardTypeOption, RuleDraft, RuleKind, RuleParamsDraft } from './types';

let seq = 0;
/** Stable client key for pools/rules/assets (also sent as pool `key` to save_campaign). */
export function newKey(prefix = 'k'): string {
  const uuid = globalThis.crypto?.randomUUID?.();
  if (uuid) return `${prefix}_${uuid.replace(/-/g, '').slice(0, 12)}`;
  seq += 1;
  return `${prefix}_${Date.now().toString(36)}${seq.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

export function isEditable(draft: Pick<CampaignDraft, 'status'>): boolean {
  return EDITABLE_STATUSES.includes(draft.status);
}

export function sortPlatforms(list: readonly Platform[]): Platform[] {
  return PLATFORMS.filter((p) => list.includes(p));
}

/** Reward types an org may use: global (owner NULL) or its own (save_campaign: owner_org_id is null or = org). */
export function usableRewardTypes(ctx: Pick<BuilderContext, 'rewardTypes' | 'org'>): RewardTypeOption[] {
  return ctx.rewardTypes.filter((rt) => rt.owner_org_id === null || rt.owner_org_id === ctx.org.id);
}

export function rewardTypeById(ctx: Pick<BuilderContext, 'rewardTypes'>, id: string | null | undefined): RewardTypeOption | undefined {
  return id ? ctx.rewardTypes.find((rt) => rt.id === id) : undefined;
}

export function defaultRewardType(ctx: Pick<BuilderContext, 'rewardTypes' | 'org'>): RewardTypeOption | undefined {
  const usable = usableRewardTypes(ctx);
  return usable.find((rt) => rt.code === 'IDR' && rt.owner_org_id === null) ?? usable.find((rt) => rt.kind === 'cash') ?? usable[0];
}

export function emptyParams(kind: RuleKind): RuleParamsDraft {
  switch (kind) {
    case 'per_1k_views':
      return { rate: null };
    case 'flat_per_post':
      return { amount: null };
    case 'milestone_bonus':
      return { threshold: null, amount: null };
    case 'tiered_cpm':
      return { tiers: [{ from: 0, to: null, rate: null }] };
  }
}

export function newPool(rewardTypeId: string): PoolDraft {
  return { key: newKey('pool'), id: null, reward_type_id: rewardTypeId, total: null, max_per_clip: null };
}

export function newRule(pool: string, kind: RuleKind = 'per_1k_views', platform: Platform | null = null): RuleDraft {
  return { key: newKey('rule'), kind, pool, platform, params: emptyParams(kind) };
}

/** Fresh draft for brand.{domain}/[org]/campaigns/new: column defaults of market.campaigns + one IDR pool with a CPM rule. */
export function newDraft(ctx: Pick<BuilderContext, 'org' | 'rewardTypes' | 'platforms'>): CampaignDraft {
  const rt = defaultRewardType(ctx);
  const pool = rt ? newPool(rt.id) : null;
  return {
    id: null,
    org_id: ctx.org.id,
    status: 'draft',
    title: '',
    slug: '',
    type: 'clipping',
    category_id: null,
    cover: null,
    service_mode: 'self_serve',
    brief: '',
    managed_brief: '',
    dos: [],
    donts: [],
    example_urls: [],
    required_hashtags: [],
    required_mentions: [],
    required_links: [],
    min_duration_sec: null,
    max_duration_sec: null,
    sponsored_label: DEFAULTS.sponsored_label,
    faq: [],
    assets: [],
    internal_files: [],
    // save_campaign needs ≥ 1 platform to create the row (campaigns.platforms NOT NULL, cardinality ≥ 1).
    platforms: PLATFORMS.filter((p) => ctx.platforms[p]),
    pools: pool ? [pool] : [],
    rules: pool ? [newRule(pool.key)] : [],
    min_views: DEFAULTS.min_views,
    max_clips_per_clipper: DEFAULTS.max_clips_per_clipper,
    clipper_quota: null,
    allow_video_reuse: false,
    min_followers: 0,
    min_account_age_days: 0,
    min_trust_score: 0,
    kyc_required: false,
    visibility: DEFAULTS.visibility,
    start_at: null,
    submit_deadline: null,
    view_window_days: DEFAULTS.view_window_days,
    review_mode: DEFAULTS.review_mode,
    is_template: false,
    fee: { mode: 'keep' },
  };
}

/** market.rule_rate: rate per 1.000 views (tiered_cpm = first tier); null for rules not paid per views. */
export function ruleRatePer1k(rule: Pick<RuleDraft, 'kind' | 'params'>): number | null {
  if (rule.kind === 'per_1k_views') return rule.params.rate ?? null;
  if (rule.kind === 'tiered_cpm') return rule.params.tiers?.[0]?.rate ?? null;
  return null;
}

/**
 * Earning of one rule for a clip with `views` cumulative views (finance.rule_amount + accrual semantics):
 * per_1k_views linear, tiered_cpm marginal per tier, flat_per_post = amount, milestone_bonus = amount once views ≥ threshold.
 */
export function earningForViews(rule: Pick<RuleDraft, 'kind' | 'params'>, views: number): number | null {
  const p = rule.params;
  switch (rule.kind) {
    case 'per_1k_views':
      return p.rate == null ? null : (views * p.rate) / 1000;
    case 'flat_per_post':
      return p.amount ?? null;
    case 'milestone_bonus':
      return p.amount == null || p.threshold == null ? null : views >= p.threshold ? p.amount : 0;
    case 'tiered_cpm': {
      const tiers = p.tiers ?? [];
      if (tiers.length === 0 || tiers.some((t) => t.rate == null)) return null;
      let total = 0;
      for (const t of tiers) {
        const lo = Math.max(0, t.from ?? 0);
        const hi = Math.min(views, t.to ?? views);
        if (hi > lo) total += ((hi - lo) * (t.rate ?? 0)) / 1000;
      }
      return total;
    }
  }
}

/* ───────────── Step 3 "rate per platform" = per_1k_views rules on the first pool ───────────── */

export type BaseRateMode = 'same' | 'per_platform' | 'custom' | 'none';

export function basePool(draft: Pick<CampaignDraft, 'pools'>): PoolDraft | undefined {
  return draft.pools[0];
}

export function baseRules(draft: Pick<CampaignDraft, 'pools' | 'rules'>): RuleDraft[] {
  const pool = basePool(draft);
  if (!pool) return [];
  return draft.rules.filter((r) => r.kind === 'per_1k_views' && r.pool === pool.key);
}

export function baseRateMode(draft: Pick<CampaignDraft, 'pools' | 'rules'>): BaseRateMode {
  const rules = baseRules(draft);
  if (rules.length === 0) return 'none';
  if (rules.length === 1 && rules[0]!.platform === null) return 'same';
  const platforms = rules.map((r) => r.platform);
  if (platforms.every((p) => p !== null) && new Set(platforms).size === platforms.length) return 'per_platform';
  return 'custom';
}

function replaceBaseRules(draft: CampaignDraft, next: RuleDraft[]): CampaignDraft {
  const base = new Set(baseRules(draft).map((r) => r.key));
  return { ...draft, rules: [...next, ...draft.rules.filter((r) => !base.has(r.key))] };
}

/** Switch step-3 mode. Rates carry over (same → every platform gets the shared rate; per-platform → first rate). */
export function setBaseRateMode(draft: CampaignDraft, mode: 'same' | 'per_platform'): CampaignDraft {
  const pool = basePool(draft);
  if (!pool) return draft;
  const current = baseRules(draft);
  const shared = current.find((r) => r.platform === null)?.params.rate ?? current[0]?.params.rate ?? null;
  if (mode === 'same') {
    const keep = current[0];
    return replaceBaseRules(draft, [{ key: keep?.key ?? newKey('rule'), kind: 'per_1k_views', pool: pool.key, platform: null, params: { rate: shared } }]);
  }
  const next = sortPlatforms(draft.platforms).map((p) => {
    const existing = current.find((r) => r.platform === p);
    return existing ?? { key: newKey('rule'), kind: 'per_1k_views' as const, pool: pool.key, platform: p, params: { rate: shared } };
  });
  return replaceBaseRules(draft, next);
}

export function setBaseRate(draft: CampaignDraft, platform: Platform | null, rate: number | null): CampaignDraft {
  const pool = basePool(draft);
  if (!pool) return draft;
  const target = baseRules(draft).find((r) => r.platform === platform);
  if (target) {
    return { ...draft, rules: draft.rules.map((r) => (r.key === target.key ? { ...r, params: { ...r.params, rate } } : r)) };
  }
  return { ...draft, rules: [{ key: newKey('rule'), kind: 'per_1k_views', pool: pool.key, platform, params: { rate } }, ...draft.rules] };
}

/** Platform checkbox. In per-platform mode the base rule of that platform is added/removed with it. */
export function togglePlatform(draft: CampaignDraft, platform: Platform, on: boolean): CampaignDraft {
  const platforms = sortPlatforms(on ? [...draft.platforms, platform] : draft.platforms.filter((p) => p !== platform));
  let next: CampaignDraft = { ...draft, platforms };
  if (baseRateMode(draft) === 'per_platform') {
    const pool = basePool(draft)!;
    const rules = baseRules(draft);
    if (on && !rules.some((r) => r.platform === platform)) {
      const rate = rules[0]?.params.rate ?? null;
      next = replaceBaseRules(next, sortRules([...rules, { key: newKey('rule'), kind: 'per_1k_views', pool: pool.key, platform, params: { rate } }]));
    } else if (!on) {
      next = replaceBaseRules(next, rules.filter((r) => r.platform !== platform));
    }
  }
  return next;
}

function sortRules(rules: RuleDraft[]): RuleDraft[] {
  const order = (p: Platform | null) => (p === null ? -1 : PLATFORMS.indexOf(p));
  return [...rules].sort((a, b) => order(a.platform) - order(b.platform));
}

/** Remove a pool and every rule paying from it. */
export function removePool(draft: CampaignDraft, key: string): CampaignDraft {
  return { ...draft, pools: draft.pools.filter((p) => p.key !== key), rules: draft.rules.filter((r) => r.pool !== key) };
}
