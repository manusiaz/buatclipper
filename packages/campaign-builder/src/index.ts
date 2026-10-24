// @clipper/campaign-builder — 7-step campaign builder (F-B02) shared by brand.{domain} and admin.{domain} (F-A03).
// The component module is 'use client'; everything else here is pure and safe to import from server components
// (e.g. draftFromDetail in a page that loads api.campaign_detail).

export { CampaignBuilder } from './builder';
export { draftFromDetail } from './detail';
export { toSavePayload, cleanFaq, ruleParamsPayload, assetsPayload, payloadHasPools } from './payload';
export { persistCampaign, splitSavePayload, untilReplicated, ADMIN_KEYS, type PersistClients } from './persist';
export { costSummary, estimatePoolViews, capInViews, type CostSummary, type CostContext, type PoolCost, type PoolEstimate } from './cost';
export {
  campaignDraftSchema,
  ruleSchema,
  poolSchema,
  assetSchema,
  faqItemSchema,
  feeOverrideSchema,
  schemaIssues,
  submitIssues,
  draftIssues,
  fieldStep,
  poolsReady,
  isPoolOrRuleIssue,
  ruleParamIssues,
  type DraftIssue,
} from './schema';
export { mapServerError, SERVER_ERRORS, type MappedServerError } from './errors';
export {
  newDraft,
  newKey,
  isEditable,
  usableRewardTypes,
  ruleRatePer1k,
  earningForViews,
  baseRateMode,
  type BaseRateMode,
} from './model';
export { normalizeHashtag, normalizeMention, normalizeLink, normalizeList, type ListKind } from './normalize';
export { checkFile, normalizeMime, putToSignedUrl, signedUploadRequest, coverPublicUrl } from './upload';
export { toWibInput, fromWibInput } from './datetime';
export { SafeMarkdown, renderMarkdown, type SafeMarkdownProps } from './markdown';
export {
  PLATFORMS,
  CAMPAIGN_TYPES,
  RULE_KINDS,
  REVIEW_MODES,
  VISIBILITIES,
  STEPS,
  DEFAULTS,
  UPLOAD_LIMITS,
  EDITABLE_STATUSES,
} from './constants';
export type {
  Platform,
  RewardTypeOption,
  BuilderContext,
  SaveResult,
  BuilderActions,
  CampaignDraft,
  CampaignBuilderProps,
  CampaignType,
  CampaignStatus,
  RuleKind,
  ReviewMode,
  Visibility,
  ServiceMode,
  AssetKind,
  AssetAudience,
  UploadKind,
  TierDraft,
  RuleParamsDraft,
  PoolDraft,
  RuleDraft,
  AssetDraft,
  FaqItem,
  FeeOverride,
  StepId,
} from './types';
