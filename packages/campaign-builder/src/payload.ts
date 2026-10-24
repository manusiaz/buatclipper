import { isEditable, sortPlatforms } from './model';
import { normalizeList } from './normalize';
import { poolsReady } from './schema';
import type { AssetDraft, CampaignDraft, FaqItem, RuleDraft } from './types';

/** FAQ as stored in market.campaigns.faq: [{q, a}], trimmed, empty rows dropped. */
export function cleanFaq(faq: readonly FaqItem[]): FaqItem[] {
  return faq.map((f) => ({ q: f.q.trim(), a: f.a.trim() })).filter((f) => f.q !== '' || f.a !== '');
}

/** check_rule_params shape: only the keys of the rule's kind; tier `to` omitted when open-ended. */
export function ruleParamsPayload(rule: RuleDraft): Record<string, unknown> {
  const p = rule.params;
  switch (rule.kind) {
    case 'per_1k_views':
      return { rate: p.rate };
    case 'flat_per_post':
      return { amount: p.amount };
    case 'milestone_bonus':
      return { threshold: p.threshold, amount: p.amount };
    case 'tiered_cpm':
      return { tiers: (p.tiers ?? []).map((t) => (t.to == null ? { from: t.from, rate: t.rate } : { from: t.from, to: t.to, rate: t.rate })) };
  }
}

function assetPayload(a: AssetDraft): Record<string, unknown> {
  if (a.kind === 'link' || a.url != null) return { kind: 'link', url: a.url, audience: 'clipper' };
  const out: Record<string, unknown> = { kind: a.kind, storage_path: a.storage_path, audience: a.audience };
  if (a.size_bytes != null) out.size_bytes = a.size_bytes;
  return out;
}

/** Full asset list (save_campaign deletes assets missing from it): cover, clipper assets, internal files. */
export function assetsPayload(draft: Pick<CampaignDraft, 'cover' | 'assets' | 'internal_files'>): Record<string, unknown>[] {
  return [...(draft.cover ? [draft.cover] : []), ...draft.assets, ...draft.internal_files].map(assetPayload);
}

/** True when toSavePayload will carry pools + rules (they are held back while incomplete). */
export function payloadHasPools(draft: CampaignDraft): boolean {
  return isEditable(draft) && poolsReady(draft);
}

/**
 * Exact p_campaign of api.save_campaign.
 * - Submitted campaigns (status ≠ draft/rejected): only {id, faq} — anything else raises campaign_locked.
 * - New campaign: org_id (no id). Existing: id (org_id omitted; it cannot change).
 * - slug only when set by the user (otherwise the server generates it on insert and keeps it).
 * - pools/rules only when every pool and rule is complete and valid; otherwise both keys are omitted so the server keeps
 *   the last saved set (a partial set would fail invalid:pool / invalid:rule_params and block the whole draft).
 * - assets always as the complete list; fee_rule only in admin override mode (set → object, clear → null).
 */
export function toSavePayload(draft: CampaignDraft): Record<string, unknown> {
  if (!isEditable(draft)) {
    return { id: draft.id, faq: cleanFaq(draft.faq) };
  }
  const p: Record<string, unknown> = {};
  if (draft.id) p.id = draft.id;
  else p.org_id = draft.org_id;

  p.title = draft.title.trim();
  const slug = draft.slug.trim().toLowerCase();
  if (slug) p.slug = slug;
  p.type = draft.type;
  p.category_id = draft.category_id;
  p.platforms = sortPlatforms(draft.platforms);

  p.service_mode = draft.service_mode;
  p.brief = draft.brief;
  if (draft.service_mode === 'managed' || draft.managed_brief) p.managed_brief = draft.managed_brief;
  p.required_hashtags = normalizeList('hashtag', draft.required_hashtags).values;
  p.required_mentions = normalizeList('mention', draft.required_mentions).values;
  p.required_links = normalizeList('link', draft.required_links).values;
  p.example_urls = normalizeList('link', draft.example_urls).values;
  p.dos = normalizeList('text', draft.dos).values;
  p.donts = normalizeList('text', draft.donts).values;
  p.min_duration_sec = draft.min_duration_sec;
  p.max_duration_sec = draft.max_duration_sec;
  p.sponsored_label = draft.sponsored_label;
  p.faq = cleanFaq(draft.faq);

  p.min_views = draft.min_views;
  p.max_clips_per_clipper = draft.max_clips_per_clipper;
  p.clipper_quota = draft.clipper_quota;
  p.allow_video_reuse = draft.allow_video_reuse;

  p.min_followers = draft.min_followers;
  p.min_account_age_days = draft.min_account_age_days;
  p.min_trust_score = draft.min_trust_score;
  p.kyc_required = draft.kyc_required;
  p.visibility = draft.visibility;

  p.start_at = draft.start_at;
  p.submit_deadline = draft.submit_deadline;
  p.view_window_days = draft.view_window_days;
  p.review_mode = draft.review_mode;
  p.is_template = draft.is_template;

  if (poolsReady(draft)) {
    p.pools = draft.pools.map((pool) => ({
      ...(pool.id ? { id: pool.id } : {}),
      key: pool.key,
      reward_type_id: pool.reward_type_id,
      total: pool.total,
      max_per_clip: pool.max_per_clip,
    }));
    p.rules = draft.rules.map((r) => ({
      kind: r.kind,
      pool: r.pool,
      ...(r.platform ? { platform: r.platform } : {}),
      params: ruleParamsPayload(r),
    }));
  }

  p.assets = assetsPayload(draft);

  if (draft.fee.mode === 'clear') p.fee_rule = null;
  else if (draft.fee.mode === 'set') p.fee_rule = { mgmt_fee_pct: draft.fee.mgmt_fee_pct, admin_fee_pct: draft.fee.admin_fee_pct };

  return p;
}
