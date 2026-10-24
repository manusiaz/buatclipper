import { fieldStep } from './schema';
import type { StepId } from './types';

/**
 * Server error → wizard step + field + i18n key. save_campaign raises message = machine code (api/_helpers.sql:
 * invalid:<field>, campaign_locked, org_not_verified, …) with Indonesian DETAIL for logs; constraint violations surface
 * as Postgres messages naming the constraint/column.
 */
export interface MappedServerError {
  code: string;
  /** Step to jump to; null = general (banner on the current screen). */
  step: StepId | null;
  /** Field path for an inline message (null = step-level banner). */
  field: string | null;
  /** i18n key in the `builder` namespace. */
  message: string;
  detail?: string;
}

type Target = Omit<MappedServerError, 'code' | 'detail'>;
const at = (step: StepId | null, field: string | null, message: string): Target => ({ step, field, message });

export const SERVER_ERRORS: Record<string, Target> = {
  'invalid:payload': at(null, null, 'server.payload'),
  'invalid:unknown_key': at(null, null, 'server.payload'),
  'invalid:org_id': at(null, null, 'server.orgId'),
  'invalid:slug': at('basics', 'slug', 'errors.slugFormat'),
  slug_taken: at('basics', 'slug', 'server.slugTaken'),
  'invalid:required_hashtags': at('brief', 'required_hashtags', 'errors.hashtag'),
  'invalid:required_mentions': at('brief', 'required_mentions', 'errors.mention'),
  'invalid:required_links': at('brief', 'required_links', 'errors.linkHttps'),
  'invalid:example_urls': at('brief', 'example_urls', 'errors.linkHttps'),
  'invalid:dos': at('brief', 'dos', 'server.list'),
  'invalid:donts': at('brief', 'donts', 'server.list'),
  'invalid:asset_url': at('brief', 'assets', 'errors.linkHttps'),
  'invalid:asset_path': at('brief', 'assets', 'server.assetPath'),
  'invalid:assets': at('brief', 'assets', 'server.payload'),
  'invalid:pools': at('rewards', 'pools', 'errors.poolsRequired'),
  'invalid:pool': at('budget', 'pools', 'server.pool'),
  'invalid:pool_id': at('rewards', 'pools', 'server.poolId'),
  'invalid:pool_in_use': at('rewards', 'pools', 'server.poolInUse'),
  'invalid:reward_type': at('rewards', 'pools', 'server.rewardType'),
  'invalid:rules': at('rewards', 'rules', 'errors.poolNeedsRule'),
  'invalid:rule_params': at('rewards', 'rules', 'server.ruleParams'),
  'invalid:rule_kind': at('rewards', 'rules', 'server.ruleParams'),
  'invalid:rule_platform': at('rewards', 'rules', 'errors.rulePlatform'),
  'invalid:rule_pool': at('rewards', 'rules', 'errors.rulePool'),
  'invalid:rule_reward_type': at('rewards', 'rules', 'server.ruleRewardType'),
  'invalid:schedule': at('schedule', 'start_at', 'server.schedule'),
  'invalid:submit_deadline': at('schedule', 'submit_deadline', 'errors.deadlinePast'),
  'invalid:template': at('summary', null, 'errors.templateSubmit'),
  'invalid:fee_rule': at('summary', 'fee', 'server.feeRule'),
  campaign_locked: at(null, null, 'server.locked'),
  org_not_verified: at('summary', null, 'server.orgNotVerified'),
  org_suspended: at(null, null, 'server.orgSuspended'),
  pools_locked_after_payment: at('budget', 'pools', 'server.poolsLocked'),
  'config:fee_rule_missing': at(null, null, 'server.feeRuleMissing'),
  'auth:forbidden': at(null, null, 'server.forbidden'),
  'auth:no_session': at(null, null, 'server.noSession'),
  'not_found:campaign': at(null, null, 'server.notFoundCampaign'),
  'not_found:org': at(null, null, 'server.notFoundOrg'),
  network: at(null, null, 'server.network'),
};

/** CHECK / FK constraint names of the tables save_campaign writes. */
const CONSTRAINTS: Record<string, Target> = {
  campaigns_title_check: at('basics', 'title', 'errors.titleLength'),
  campaigns_slug_check: at('basics', 'slug', 'errors.slugFormat'),
  campaigns_slug_unique: at('basics', 'slug', 'server.slugTaken'),
  campaigns_type_check: at('basics', 'type', 'errors.type'),
  campaigns_category_id_fkey: at('basics', 'category_id', 'server.category'),
  campaigns_platforms_check: at('platforms', 'platforms', 'errors.platformsRequired'),
  campaigns_min_duration_sec_check: at('brief', 'min_duration_sec', 'errors.durationPositive'),
  campaigns_max_duration_sec_check: at('brief', 'max_duration_sec', 'errors.durationPositive'),
  campaigns_duration_range: at('brief', 'max_duration_sec', 'errors.durationRange'),
  campaigns_hashtags_format: at('brief', 'required_hashtags', 'errors.hashtag'),
  campaigns_mentions_format: at('brief', 'required_mentions', 'errors.mention'),
  campaigns_links_https: at('brief', 'required_links', 'errors.linkHttps'),
  campaigns_examples_https: at('brief', 'example_urls', 'errors.linkHttps'),
  campaigns_faq_check: at('brief', 'faq', 'server.payload'),
  campaigns_service_mode_check: at('brief', 'service_mode', 'server.payload'),
  campaigns_min_views_check: at('budget', 'min_views', 'errors.nonNegative'),
  campaigns_max_clips_per_clipper_check: at('budget', 'max_clips_per_clipper', 'errors.minOne'),
  campaigns_clipper_quota_check: at('budget', 'clipper_quota', 'errors.minOne'),
  campaigns_min_followers_check: at('eligibility', 'min_followers', 'errors.nonNegative'),
  campaigns_min_account_age_days_check: at('eligibility', 'min_account_age_days', 'errors.nonNegative'),
  campaigns_min_trust_score_check: at('eligibility', 'min_trust_score', 'errors.trustRange'),
  campaigns_visibility_check: at('eligibility', 'visibility', 'server.payload'),
  campaigns_level_has_threshold: at('eligibility', 'min_trust_score', 'errors.levelNeedsTrust'),
  campaigns_view_window_days_check: at('schedule', 'view_window_days', 'errors.viewWindowRange'),
  campaigns_review_mode_check: at('schedule', 'review_mode', 'server.payload'),
  campaigns_schedule: at('schedule', 'submit_deadline', 'errors.scheduleOrder'),
  campaigns_scheduled_has_dates: at('schedule', 'start_at', 'server.schedule'),
  campaigns_template_stays_draft: at('summary', null, 'errors.templateSubmit'),
  reward_pools_total_check: at('budget', 'pools', 'server.pool'),
  reward_pools_max_per_clip_check: at('budget', 'pools', 'server.pool'),
  rate_rules_params_per_kind: at('rewards', 'rules', 'server.ruleParams'),
  rate_rules_pool_match: at('rewards', 'rules', 'errors.rulePool'),
  campaign_assets_one_source: at('brief', 'assets', 'server.assetPath'),
  campaign_assets_link_is_url: at('brief', 'assets', 'server.assetPath'),
  campaign_assets_internal_folder: at('brief', 'internal_files', 'server.assetPath'),
  campaign_assets_cover_public: at('basics', 'cover', 'server.assetPath'),
  campaign_assets_url_check: at('brief', 'assets', 'errors.linkHttps'),
  campaign_assets_kind_check: at('brief', 'assets', 'server.payload'),
};

export function mapServerError(error: string, detail?: string): MappedServerError {
  const code = (error ?? '').trim();
  const known = SERVER_ERRORS[code];
  if (known) return { code, ...known, detail };

  const constraint = /constraint "([a-z0-9_]+)"/i.exec(code)?.[1];
  if (constraint && CONSTRAINTS[constraint]) return { code, ...CONSTRAINTS[constraint]!, detail };

  // campaigns_brief_frozen trigger (23514) — the brief is locked since submission.
  if (/brief terkunci/i.test(code)) return { code, ...SERVER_ERRORS.campaign_locked!, detail };

  const notNull = /null value in column "([a-z_]+)"/i.exec(code)?.[1];
  if (notNull) {
    const step = fieldStep([notNull]);
    return { code, step: step === 'summary' ? null : step, field: notNull, message: 'errors.required', detail };
  }
  if (/market\.platform/.test(code)) return { code, step: 'platforms', field: 'platforms', message: 'errors.platformsRequired', detail };

  if (code.startsWith('invalid_state:')) return { code, step: null, field: null, message: 'server.locked', detail };
  if (code.startsWith('not_found:')) return { code, step: null, field: null, message: 'server.notFoundCampaign', detail };
  if (code.startsWith('auth:')) return { code, step: null, field: null, message: 'server.forbidden', detail };
  if (code.startsWith('invalid:')) {
    const field = code.slice('invalid:'.length);
    const step = fieldStep([field]);
    if (step !== 'summary') return { code, step, field, message: 'server.invalidField', detail };
  }
  return { code, step: null, field: null, message: 'server.generic', detail };
}
