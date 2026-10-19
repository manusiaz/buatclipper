import type { ReactNode, JSX } from 'react';

/** market.platform enum. */
export type Platform = 'tiktok' | 'instagram' | 'youtube' | 'threads' | 'facebook' | 'x';
/** market.campaigns.type CHECK. */
export type CampaignType = 'clipping' | 'ugc' | 'music' | 'logo' | 'text';
/** market.campaign_status enum (S-01). */
export type CampaignStatus =
  | 'draft'
  | 'in_review'
  | 'cancelled'
  | 'scheduled'
  | 'rejected'
  | 'live'
  | 'paused'
  | 'tracking'
  | 'exhausted'
  | 'settling'
  | 'settled';
/** market.rate_rules.kind CHECK (§10.2). */
export type RuleKind = 'per_1k_views' | 'flat_per_post' | 'milestone_bonus' | 'tiered_cpm';
export type ReviewMode = 'auto' | 'manual' | 'brand';
/** invite = campaign privat (F-B11), level = minimal Trust Score. */
export type Visibility = 'public' | 'invite' | 'level';
export type ServiceMode = 'self_serve' | 'managed';
/** market.campaign_assets.kind CHECK. */
export type AssetKind = 'cover' | 'video' | 'image' | 'audio' | 'document' | 'link';
export type AssetAudience = 'clipper' | 'internal';
export type UploadKind = 'cover' | 'asset' | 'internal';

export interface RewardTypeOption {
  id: string;
  code: string;
  name: string;
  unit_label: string;
  kind: string;
  idr_value_per_unit: number;
  decimals: number;
  owner_org_id: string | null;
}

export interface BuilderContext {
  mode: 'brand' | 'admin';
  org: { id: string; name: string; status: 'pending_verification' | 'verified' | 'suspended' };
  categories: { id: string; name_id: string; name_en: string }[];
  rewardTypes: RewardTypeOption[];
  /** public.flags.platforms */
  platforms: Record<Platform, boolean>;
  /** Effective fee rule for this org (campaign → org → global). */
  fee: { mgmt_fee_pct: number; admin_fee_pct: number };
  /** public.billing.tax_pct */
  taxPct: number;
  /** public.billing.managed_service_idr */
  managedServiceIdr: number;
  /** Admin mode: fee rules offered as per-campaign override (F-A03). */
  feeRules?: { id: string; scope: string; mgmt_fee_pct: number; admin_fee_pct: number }[];
}

export type SaveResult = { ok: true; id: string } | { ok: false; error: string; detail?: string };

export interface BuilderActions {
  /** Server action wrapping api.save_campaign(p_campaign, p_submit). */
  save(payload: Record<string, unknown>, submit: boolean): Promise<SaveResult>;
  /** Server action: storage createSignedUploadUrl (cover → campaign-covers, asset/internal → campaign-assets). */
  uploadUrl(input: {
    campaignId: string;
    kind: UploadKind;
    filename: string;
    contentType: string;
    size: number;
  }): Promise<{ ok: true; path: string; signedUrl: string } | { ok: false; error: string }>;
}

/** One tier of a tiered_cpm rule; `to` null = open-ended (last tier only). */
export interface TierDraft {
  from: number | null;
  to: number | null;
  rate: number | null;
}

/** Params per kind (§10.2). Only the keys of the rule's kind are sent. */
export interface RuleParamsDraft {
  rate?: number | null;
  amount?: number | null;
  threshold?: number | null;
  tiers?: TierDraft[];
}

/** E-09 pool. `key` is stable in the builder; `id` is the server id once loaded. */
export interface PoolDraft {
  key: string;
  id: string | null;
  reward_type_id: string;
  total: number | null;
  max_per_clip: number | null;
}

/** E-08 rule. `pool` = PoolDraft.key. platform null = all campaign platforms. */
export interface RuleDraft {
  key: string;
  kind: RuleKind;
  pool: string;
  platform: Platform | null;
  params: RuleParamsDraft;
}

/** E-10 asset. File assets carry storage_path (bucket path {org}/{campaign}/…), links carry url. */
export interface AssetDraft {
  key: string;
  id: string | null;
  kind: AssetKind;
  audience: AssetAudience;
  storage_path: string | null;
  url: string | null;
  size_bytes: number | null;
  /** Display name (file name or link host). Not sent. */
  name: string | null;
}

export interface FaqItem {
  q: string;
  a: string;
}

/** Admin-only per-campaign fee override (F-A03). keep = not sent; clear = fee_rule null; set = new campaign fee rule. */
export type FeeOverride =
  | { mode: 'keep' }
  | { mode: 'clear' }
  | { mode: 'set'; source_id: string | null; mgmt_fee_pct: number; admin_fee_pct: number };

/**
 * Typed draft model. Column fields use the market.campaigns column names so the zod schema and the payload
 * mirror the SQL contract one-to-one.
 */
export interface CampaignDraft {
  id: string | null;
  org_id: string;
  status: CampaignStatus;
  // (1) dasar
  title: string;
  /** Empty = server generates from the title. */
  slug: string;
  type: CampaignType;
  category_id: string | null;
  cover: AssetDraft | null;
  // (2) brief & aset
  service_mode: ServiceMode;
  brief: string;
  dos: string[];
  donts: string[];
  example_urls: string[];
  required_hashtags: string[];
  required_mentions: string[];
  required_links: string[];
  min_duration_sec: number | null;
  max_duration_sec: number | null;
  sponsored_label: boolean;
  faq: FaqItem[];
  /** audience clipper (brief assets: files + links). */
  assets: AssetDraft[];
  /** audience internal (raw brief files for the managed package, folder internal/). */
  internal_files: AssetDraft[];
  // (3) platform & rate
  platforms: Platform[];
  // (4) reward & rule, (5) budget
  pools: PoolDraft[];
  rules: RuleDraft[];
  min_views: number | null;
  max_clips_per_clipper: number | null;
  clipper_quota: number | null;
  allow_video_reuse: boolean;
  // (6) eligibility
  min_followers: number | null;
  min_account_age_days: number | null;
  min_trust_score: number | null;
  kyc_required: boolean;
  visibility: Visibility;
  // (7) jadwal & review
  /** ISO timestamp (UTC) or null. Edited in WIB. */
  start_at: string | null;
  submit_deadline: string | null;
  view_window_days: number | null;
  review_mode: ReviewMode;
  is_template: boolean;
  fee: FeeOverride;
}

export interface CampaignBuilderProps {
  context: BuilderContext;
  initial?: CampaignDraft | null;
  actions: BuilderActions;
  /** Called after every successful save (submitted = p_submit was true). */
  onSaved?: (id: string, submitted: boolean) => void;
  /** Admin: brand's raw brief + internal files, shown next to the wizard. */
  sidePanel?: ReactNode;
}

export type CampaignBuilderComponent = (props: CampaignBuilderProps) => JSX.Element;

/** Wizard steps (7, §8 F-B02) + the summary screen. */
export type StepId = 'basics' | 'brief' | 'platforms' | 'rewards' | 'budget' | 'eligibility' | 'schedule' | 'summary';
