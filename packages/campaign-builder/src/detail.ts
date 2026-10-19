import { CAMPAIGN_STATUSES, CAMPAIGN_TYPES, DEFAULTS, PLATFORMS, REVIEW_MODES, RULE_KINDS, VISIBILITIES } from './constants';
import { newKey } from './model';
import type {
  AssetDraft,
  AssetKind,
  CampaignDraft,
  CampaignStatus,
  CampaignType,
  FaqItem,
  Platform,
  PoolDraft,
  ReviewMode,
  RuleDraft,
  RuleKind,
  RuleParamsDraft,
  TierDraft,
  Visibility,
} from './types';

type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === 'string' ? v : null);
/** numeric from jsonb (number, or numeric text). */
const num = (v: unknown): number | null => {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim())) return Number(v);
  return null;
};
const bool = (v: unknown, fallback: boolean): boolean => (typeof v === 'boolean' ? v : fallback);
const strArr = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);
const oneOf = <T extends string>(v: unknown, list: readonly T[], fallback: T): T => (list.includes(v as T) ? (v as T) : fallback);
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isObj) : []);

function paramsFromJson(kind: RuleKind, raw: unknown): RuleParamsDraft {
  const p = isObj(raw) ? raw : {};
  switch (kind) {
    case 'per_1k_views':
      return { rate: num(p.rate) };
    case 'flat_per_post':
      return { amount: num(p.amount) };
    case 'milestone_bonus':
      return { threshold: num(p.threshold), amount: num(p.amount) };
    case 'tiered_cpm':
      return { tiers: arr(p.tiers).map<TierDraft>((t) => ({ from: num(t.from), to: num(t.to), rate: num(t.rate) })) };
  }
}

function assetFromJson(a: Obj): AssetDraft {
  const path = str(a.storage_path);
  const url = str(a.url);
  return {
    key: str(a.id) ?? newKey('asset'),
    id: str(a.id),
    kind: oneOf<AssetKind>(a.kind, ['cover', 'video', 'image', 'audio', 'document', 'link'], url ? 'link' : 'document'),
    audience: a.audience === 'internal' ? 'internal' : 'clipper',
    storage_path: path,
    url,
    size_bytes: num(a.size_bytes),
    name: path ? (path.split('/').pop() ?? path) : url,
  };
}

/**
 * Draft from api.campaign_detail(p_campaign) jsonb: {campaign: {...columns}, pools: [{pool_id, reward_type_id, code, total,
 * max_per_clip, …}], rules: [{rule_id, kind, platform, pool_id, params, …}], assets: [{id, kind, audience, url, storage_path,
 * size_bytes, bucket}]}. Pools/rules come from market.campaign_budget (active rules only). The fee override and the raw
 * fee_rule_id are not part of the read model, so `fee` starts as {mode: 'keep'}.
 */
export function draftFromDetail(detail: unknown): CampaignDraft {
  const root = isObj(detail) ? detail : {};
  const c = isObj(root.campaign) ? root.campaign : null;
  if (!c || typeof c.id !== 'string' || typeof c.org_id !== 'string') {
    throw new Error('draftFromDetail: expected api.campaign_detail jsonb with campaign.id and campaign.org_id');
  }

  // Pool order = market.campaign_budget order (code, id); the IDR pool is moved first because step 3 edits the
  // per-views rates of the first pool.
  const poolRows = arr(root.pools);
  const ordered = [...poolRows.filter((p) => p.code === 'IDR'), ...poolRows.filter((p) => p.code !== 'IDR')];
  const pools: PoolDraft[] = ordered
    .filter((p) => typeof p.pool_id === 'string' && typeof p.reward_type_id === 'string')
    .map((p) => ({
      key: p.pool_id as string,
      id: p.pool_id as string,
      reward_type_id: p.reward_type_id as string,
      total: num(p.total),
      max_per_clip: num(p.max_per_clip),
    }));

  const rules: RuleDraft[] = arr(root.rules)
    .filter((r) => typeof r.pool_id === 'string' && RULE_KINDS.includes(r.kind as RuleKind))
    .map((r) => {
      const kind = r.kind as RuleKind;
      return {
        key: str(r.rule_id) ?? newKey('rule'),
        kind,
        pool: r.pool_id as string,
        platform: PLATFORMS.includes(r.platform as Platform) ? (r.platform as Platform) : null,
        params: paramsFromJson(kind, r.params),
      };
    });

  const assets = arr(root.assets).map(assetFromJson);
  const faq: FaqItem[] = arr(c.faq).map((f) => ({ q: str(f.q) ?? '', a: str(f.a) ?? '' }));

  return {
    id: c.id,
    org_id: c.org_id,
    status: oneOf<CampaignStatus>(c.status, CAMPAIGN_STATUSES, 'draft'),
    title: str(c.title) ?? '',
    slug: str(c.slug) ?? '',
    type: oneOf<CampaignType>(c.type, CAMPAIGN_TYPES, 'clipping'),
    category_id: str(c.category_id),
    cover: assets.find((a) => a.kind === 'cover') ?? null,
    service_mode: c.service_mode === 'managed' ? 'managed' : 'self_serve',
    brief: str(c.brief) ?? '',
    dos: strArr(c.dos),
    donts: strArr(c.donts),
    example_urls: strArr(c.example_urls),
    required_hashtags: strArr(c.required_hashtags),
    required_mentions: strArr(c.required_mentions),
    required_links: strArr(c.required_links),
    min_duration_sec: num(c.min_duration_sec),
    max_duration_sec: num(c.max_duration_sec),
    sponsored_label: bool(c.sponsored_label, DEFAULTS.sponsored_label),
    faq,
    assets: assets.filter((a) => a.kind !== 'cover' && a.audience === 'clipper'),
    internal_files: assets.filter((a) => a.kind !== 'cover' && a.audience === 'internal'),
    platforms: PLATFORMS.filter((p) => strArr(c.platforms).includes(p)),
    pools,
    rules,
    min_views: num(c.min_views) ?? DEFAULTS.min_views,
    max_clips_per_clipper: num(c.max_clips_per_clipper) ?? DEFAULTS.max_clips_per_clipper,
    clipper_quota: num(c.clipper_quota),
    allow_video_reuse: bool(c.allow_video_reuse, false),
    min_followers: num(c.min_followers) ?? 0,
    min_account_age_days: num(c.min_account_age_days) ?? 0,
    min_trust_score: num(c.min_trust_score) ?? 0,
    kyc_required: bool(c.kyc_required, false),
    visibility: oneOf<Visibility>(c.visibility, VISIBILITIES, DEFAULTS.visibility),
    start_at: str(c.start_at),
    submit_deadline: str(c.submit_deadline),
    view_window_days: num(c.view_window_days) ?? DEFAULTS.view_window_days,
    review_mode: oneOf<ReviewMode>(c.review_mode, REVIEW_MODES, DEFAULTS.review_mode),
    is_template: bool(c.is_template, false),
    fee: { mode: 'keep' },
  };
}
