import type { AssetKind, CampaignStatus, CampaignType, Platform, ReviewMode, RuleKind, StepId, UploadKind, Visibility } from './types';

/** market.platform enum order. */
export const PLATFORMS = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'] as const satisfies readonly Platform[];
/** market.campaigns.type CHECK (Clipping, UGC, Musik/Sound, Logo, Teks). */
export const CAMPAIGN_TYPES = ['clipping', 'ugc', 'music', 'logo', 'text'] as const satisfies readonly CampaignType[];
export const RULE_KINDS = ['per_1k_views', 'flat_per_post', 'milestone_bonus', 'tiered_cpm'] as const satisfies readonly RuleKind[];
export const REVIEW_MODES = ['manual', 'brand', 'auto'] as const satisfies readonly ReviewMode[];
export const VISIBILITIES = ['public', 'invite', 'level'] as const satisfies readonly Visibility[];
export const ASSET_KINDS = ['cover', 'video', 'image', 'audio', 'document', 'link'] as const satisfies readonly AssetKind[];
export const CAMPAIGN_STATUSES = [
  'draft',
  'in_review',
  'cancelled',
  'scheduled',
  'rejected',
  'live',
  'paused',
  'tracking',
  'exhausted',
  'settling',
  'settled',
] as const satisfies readonly CampaignStatus[];

/** save_campaign accepts every column only in these statuses; afterwards only faq (campaigns_brief_frozen). */
export const EDITABLE_STATUSES: readonly CampaignStatus[] = ['draft', 'rejected'];

export const STEPS = ['basics', 'brief', 'platforms', 'rewards', 'budget', 'eligibility', 'schedule'] as const satisfies readonly StepId[];

/** Column defaults of market.campaigns (§10.3). */
export const DEFAULTS = {
  min_views: 1000,
  max_clips_per_clipper: 10,
  view_window_days: 30,
  review_mode: 'manual' as ReviewMode,
  visibility: 'public' as Visibility,
  sponsored_label: true,
} as const;

/** Numeric bounds from market.campaigns column types / CHECKs. */
export const LIMITS = {
  titleMin: 3,
  titleMax: 120,
  smallintMax: 32767,
  intMax: 2147483647,
  viewWindowMin: 1,
  viewWindowMax: 90,
  trustMax: 100,
} as const;

export const SLUG_RE = /^[a-z0-9-]{3,80}$/;
/** [[:lower:][:digit:]_] after lower() (market.norm_list 'hashtag', campaigns_hashtags_format). */
export const HASHTAG_RE = /^[\p{Ll}0-9_]+$/u;
/** [[:lower:][:digit:]_.] (market.norm_list 'mention', campaigns_mentions_format). */
export const MENTION_RE = /^[\p{Ll}0-9_.]+$/u;
/** campaigns_links_https / campaigns_examples_https / campaign_assets.url. */
export const HTTPS_RE = /^https:\/\/\S+$/;

/** Views used for the "10.000 views = RpX" example (PRD C1.1). */
export const EXAMPLE_VIEWS = 10_000;

const MIB = 1024 * 1024;

/** Bucket limits from db/core/supabase/config.toml (enforced client-side before upload). */
export const UPLOAD_LIMITS: Record<UploadKind, { bucket: string; maxBytes: number; mime: readonly string[] }> = {
  cover: { bucket: 'campaign-covers', maxBytes: 2 * MIB, mime: ['image/jpeg', 'image/png', 'image/webp'] },
  asset: {
    bucket: 'campaign-assets',
    maxBytes: 500 * MIB,
    mime: ['video/mp4', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp', 'audio/mpeg', 'audio/wav', 'application/pdf'],
  },
  internal: {
    bucket: 'campaign-assets',
    maxBytes: 500 * MIB,
    mime: ['video/mp4', 'video/quicktime', 'image/jpeg', 'image/png', 'image/webp', 'audio/mpeg', 'audio/wav', 'application/pdf'],
  },
};

/** Storage-js DEFAULT_FILE_OPTIONS.cacheControl (sent as the multipart `cacheControl` field). */
export const UPLOAD_CACHE_CONTROL = '3600';
