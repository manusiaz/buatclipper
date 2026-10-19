import { z } from 'zod';
import { ASSET_KINDS, CAMPAIGN_STATUSES, CAMPAIGN_TYPES, HTTPS_RE, LIMITS, PLATFORMS, REVIEW_MODES, RULE_KINDS, SLUG_RE, VISIBILITIES } from './constants';
import { normalizeHashtag, normalizeLink, normalizeMention } from './normalize';
import type { AssetDraft, CampaignDraft, RuleDraft, StepId } from './types';

/*
 * zod v4 schema of the builder draft mirroring the SQL contract:
 *   market.campaigns CHECKs (title 3–120, slug, type, platforms ≥ 1, hashtag/mention/link formats, duration > 0 and
 *   min ≤ max, view_window 1–90, review_mode, min_followers ≥ 0, account age ≥ 0, trust 0–100, min_views ≥ 0,
 *   max_clips ≥ 1, clipper_quota ≥ 1, visibility, schedule submit_deadline > start_at, level needs min_trust_score > 0,
 *   faq array), finance.reward_pools (total > 0, max_per_clip > 0), market.check_rule_params (per kind),
 *   save_campaign (rule platform ∈ campaign platforms, rule → pool of this campaign), market.campaign_assets
 *   (one source, link ⇔ url, url https, internal/ folder ⇔ audience internal, cover is clipper-facing).
 * Messages are i18n keys of the `builder` namespace.
 */

const E = {
  required: 'errors.required',
  integer: 'errors.integer',
  nonNegative: 'errors.nonNegative',
  positive: 'errors.positive',
  tooLarge: 'errors.tooLarge',
} as const;

const intIn = (min: number, max: number, minMsg: string = E.nonNegative) =>
  z.number({ error: E.required }).int(E.integer).min(min, minMsg).max(max, E.tooLarge);
const positiveNumber = z.number({ error: E.required }).gt(0, E.positive);

const listOf = (check: (v: string) => boolean, message: string) =>
  z.array(z.string()).superRefine((items, ctx) => {
    items.forEach((v, i) => {
      if (!check(v)) ctx.addIssue({ code: 'custom', message, path: [i], input: v });
    });
  });

const tierSchema = z.object({ from: z.number().nullable(), to: z.number().nullable(), rate: z.number().nullable() });

const paramsSchema = z.object({
  rate: z.number().nullable().optional(),
  amount: z.number().nullable().optional(),
  threshold: z.number().nullable().optional(),
  tiers: z.array(tierSchema).optional(),
});

export const ruleSchema = z.object({
  key: z.string().min(1),
  kind: z.enum(RULE_KINDS),
  pool: z.string().min(1, 'errors.rulePool'),
  platform: z.enum(PLATFORMS).nullable(),
  params: paramsSchema,
});

export const poolSchema = z.object({
  key: z.string().min(1),
  id: z.string().nullable(),
  reward_type_id: z.string().min(1, 'errors.rewardTypeRequired'),
  total: positiveNumber,
  max_per_clip: positiveNumber,
});

export const assetSchema = z.object({
  key: z.string().min(1),
  id: z.string().nullable(),
  kind: z.enum(ASSET_KINDS),
  audience: z.enum(['clipper', 'internal']),
  storage_path: z.string().nullable(),
  url: z.string().nullable(),
  size_bytes: z.number().int().min(0).nullable(),
  name: z.string().nullable(),
});

export const faqItemSchema = z.object({ q: z.string(), a: z.string() });

const pctSchema = z.number({ error: E.required }).min(0, E.nonNegative).max(100, 'errors.pctRange');

export const feeOverrideSchema = z.discriminatedUnion('mode', [
  z.object({ mode: z.literal('keep') }),
  z.object({ mode: z.literal('clear') }),
  z.object({ mode: z.literal('set'), source_id: z.string().nullable(), mgmt_fee_pct: pctSchema, admin_fee_pct: pctSchema }),
]);

const isoOrNull = z
  .string()
  .nullable()
  .refine((v) => v === null || !Number.isNaN(Date.parse(v)), 'errors.dateInvalid');

const codePoints = (s: string) => [...s].length;

/** Mirror of market.check_rule_params + rule placement checks of save_campaign. Path relative to the draft. */
export function ruleParamIssues(rule: RuleDraft, index: number): { path: (string | number)[]; message: string }[] {
  const out: { path: (string | number)[]; message: string }[] = [];
  const base = ['rules', index, 'params'];
  const p = rule.params ?? {};
  const pos = (v: number | null | undefined) => typeof v === 'number' && v > 0;
  switch (rule.kind) {
    case 'per_1k_views':
      if (!pos(p.rate)) out.push({ path: [...base, 'rate'], message: 'errors.ruleRate' });
      break;
    case 'flat_per_post':
      if (!pos(p.amount)) out.push({ path: [...base, 'amount'], message: 'errors.ruleAmount' });
      break;
    case 'milestone_bonus':
      if (!pos(p.threshold)) out.push({ path: [...base, 'threshold'], message: 'errors.ruleThreshold' });
      if (!pos(p.amount)) out.push({ path: [...base, 'amount'], message: 'errors.ruleAmount' });
      break;
    case 'tiered_cpm': {
      const tiers = p.tiers ?? [];
      if (tiers.length === 0) {
        out.push({ path: [...base, 'tiers'], message: 'errors.tiersRequired' });
        break;
      }
      let prev = -1;
      tiers.forEach((t, i) => {
        const path = [...base, 'tiers', i];
        if (t.from == null) out.push({ path: [...path, 'from'], message: E.required });
        else if (i === 0 && t.from !== 0) out.push({ path: [...path, 'from'], message: 'errors.tierStart' });
        else if (t.from <= prev) out.push({ path: [...path, 'from'], message: 'errors.tierOrder' });
        if (!pos(t.rate)) out.push({ path: [...path, 'rate'], message: 'errors.ruleRate' });
        if (t.to != null && t.from != null && t.to <= t.from) out.push({ path: [...path, 'to'], message: 'errors.tierTo' });
        // Stricter than SQL (finance.rule_amount would double-pay overlapping tiers / skip gaps): tiers are contiguous
        // and only the last one is open-ended.
        const next = tiers[i + 1];
        if (next) {
          if (t.to == null) out.push({ path: [...path, 'to'], message: 'errors.tierOpenLast' });
          else if (next.from != null && next.from !== t.to) out.push({ path: [...base, 'tiers', i + 1, 'from'], message: 'errors.tierGap' });
        }
        prev = t.from ?? prev;
      });
      break;
    }
  }
  return out;
}

function assetIssues(a: AssetDraft): string | null {
  if ((a.storage_path == null) === (a.url == null)) return 'errors.assetSource';
  if ((a.kind === 'link') !== (a.url != null)) return 'errors.assetSource';
  if (a.url != null && !HTTPS_RE.test(a.url)) return 'errors.linkHttps';
  if (a.storage_path != null && (a.storage_path.split('/')[2] === 'internal') !== (a.audience === 'internal')) return 'errors.assetFolder';
  if (a.kind === 'cover' && a.audience !== 'clipper') return 'errors.assetFolder';
  return null;
}

const draftObject = z.object({
  id: z.string().nullable(),
  org_id: z.string().min(1),
  status: z.enum(CAMPAIGN_STATUSES),
  title: z.string().refine((s) => {
    const n = codePoints(s.trim());
    return n >= LIMITS.titleMin && n <= LIMITS.titleMax;
  }, 'errors.titleLength'),
  slug: z.string().refine((s) => s.trim() === '' || SLUG_RE.test(s.trim().toLowerCase()), 'errors.slugFormat'),
  type: z.enum(CAMPAIGN_TYPES, { error: 'errors.type' }),
  category_id: z.string().nullable(),
  cover: assetSchema.nullable(),
  service_mode: z.enum(['self_serve', 'managed']),
  brief: z.string(),
  dos: z.array(z.string()),
  donts: z.array(z.string()),
  example_urls: listOf((v) => normalizeLink(v).ok, 'errors.linkHttps'),
  required_hashtags: listOf((v) => normalizeHashtag(v).ok, 'errors.hashtag'),
  required_mentions: listOf((v) => normalizeMention(v).ok, 'errors.mention'),
  required_links: listOf((v) => normalizeLink(v).ok, 'errors.linkHttps'),
  min_duration_sec: z.number().int(E.integer).min(1, 'errors.durationPositive').max(LIMITS.smallintMax, E.tooLarge).nullable(),
  max_duration_sec: z.number().int(E.integer).min(1, 'errors.durationPositive').max(LIMITS.smallintMax, E.tooLarge).nullable(),
  sponsored_label: z.boolean(),
  faq: z.array(faqItemSchema),
  assets: z.array(assetSchema),
  internal_files: z.array(assetSchema),
  platforms: z.array(z.enum(PLATFORMS)).min(1, 'errors.platformsRequired'),
  pools: z.array(poolSchema),
  rules: z.array(ruleSchema),
  min_views: intIn(0, LIMITS.intMax),
  max_clips_per_clipper: intIn(1, LIMITS.smallintMax, 'errors.minOne'),
  clipper_quota: intIn(1, LIMITS.intMax, 'errors.minOne').nullable(),
  allow_video_reuse: z.boolean(),
  min_followers: intIn(0, LIMITS.intMax),
  min_account_age_days: intIn(0, LIMITS.smallintMax),
  min_trust_score: z.number({ error: E.required }).int(E.integer).min(0, 'errors.trustRange').max(LIMITS.trustMax, 'errors.trustRange'),
  kyc_required: z.boolean(),
  visibility: z.enum(VISIBILITIES),
  start_at: isoOrNull,
  submit_deadline: isoOrNull,
  view_window_days: z
    .number({ error: E.required })
    .int(E.integer)
    .min(LIMITS.viewWindowMin, 'errors.viewWindowRange')
    .max(LIMITS.viewWindowMax, 'errors.viewWindowRange'),
  review_mode: z.enum(REVIEW_MODES),
  is_template: z.boolean(),
  fee: feeOverrideSchema,
});

/** Cross-field CHECKs. Runs even when field-level issues exist so every problem is reported at once. */
function crossChecks(d: CampaignDraft, ctx: z.RefinementCtx<CampaignDraft>): void {
  const add = (path: (string | number)[], message: string) => ctx.addIssue({ code: 'custom', path, message, input: d });

  if (typeof d.min_duration_sec === 'number' && typeof d.max_duration_sec === 'number' && d.min_duration_sec > d.max_duration_sec) {
    add(['max_duration_sec'], 'errors.durationRange');
  }
  if (d.start_at && d.submit_deadline && Date.parse(d.submit_deadline) <= Date.parse(d.start_at)) {
    add(['submit_deadline'], 'errors.scheduleOrder');
  }
  if (d.visibility === 'level' && !(typeof d.min_trust_score === 'number' && d.min_trust_score > 0)) {
    add(['min_trust_score'], 'errors.levelNeedsTrust');
  }
  (d.faq ?? []).forEach((f, i) => {
    const q = f.q.trim();
    const a = f.a.trim();
    if (q === '' && a !== '') add(['faq', i, 'q'], 'errors.faqQuestion');
    if (q !== '' && a === '') add(['faq', i, 'a'], 'errors.faqAnswer');
  });
  if (d.cover) {
    const msg = d.cover.kind !== 'cover' ? 'errors.assetSource' : assetIssues(d.cover);
    if (msg) add(['cover'], msg);
  }
  (d.assets ?? []).forEach((a, i) => {
    const msg = a.kind === 'cover' || a.audience !== 'clipper' ? 'errors.assetFolder' : assetIssues(a);
    if (msg) add(['assets', i], msg);
  });
  (d.internal_files ?? []).forEach((a, i) => {
    const msg = a.audience !== 'internal' || a.kind === 'link' || a.kind === 'cover' ? 'errors.assetFolder' : assetIssues(a);
    if (msg) add(['internal_files', i], msg);
  });
  const poolKeys = new Set((d.pools ?? []).map((p) => p.key));
  (d.rules ?? []).forEach((r, i) => {
    for (const issue of ruleParamIssues(r, i)) add(issue.path, issue.message);
    if (r.platform !== null && !(d.platforms ?? []).includes(r.platform)) add(['rules', i, 'platform'], 'errors.rulePlatform');
    if (!poolKeys.has(r.pool)) add(['rules', i, 'pool'], 'errors.rulePool');
  });
}

export const campaignDraftSchema = draftObject.superRefine(crossChecks, { when: () => true });

export interface DraftIssue {
  step: StepId;
  /** Dotted path, e.g. "title", "pools.0.total", "rules.2.params.tiers.1.rate". */
  field: string;
  /** i18n key (namespace builder). */
  message: string;
}

/** Which wizard step owns a field path. */
export function fieldStep(path: readonly (string | number)[]): StepId {
  const [head, , sub] = path;
  switch (head) {
    case 'title':
    case 'slug':
    case 'type':
    case 'category_id':
    case 'cover':
      return 'basics';
    case 'service_mode':
    case 'brief':
    case 'dos':
    case 'donts':
    case 'example_urls':
    case 'required_hashtags':
    case 'required_mentions':
    case 'required_links':
    case 'min_duration_sec':
    case 'max_duration_sec':
    case 'sponsored_label':
    case 'faq':
    case 'assets':
    case 'internal_files':
      return 'brief';
    case 'platforms':
      return 'platforms';
    case 'pools':
      return sub === 'total' || sub === 'max_per_clip' ? 'budget' : 'rewards';
    case 'rules':
      return 'rewards';
    case 'min_views':
    case 'max_clips_per_clipper':
    case 'clipper_quota':
    case 'allow_video_reuse':
      return 'budget';
    case 'min_followers':
    case 'min_account_age_days':
    case 'min_trust_score':
    case 'kyc_required':
    case 'visibility':
      return 'eligibility';
    case 'start_at':
    case 'submit_deadline':
    case 'view_window_days':
    case 'review_mode':
      return 'schedule';
    default:
      return 'summary';
  }
}

const toIssue = (path: readonly PropertyKey[], message: string): DraftIssue => {
  const clean = path.filter((p): p is string | number => typeof p === 'string' || typeof p === 'number');
  return { step: fieldStep(clean), field: clean.join('.'), message };
};

/** Issues that block saving the columns (pool/rule issues only hold back `pools`/`rules`, see toSavePayload). */
export function schemaIssues(draft: CampaignDraft): DraftIssue[] {
  const res = campaignDraftSchema.safeParse(draft);
  if (res.success) return [];
  const seen = new Set<string>();
  const out: DraftIssue[] = [];
  for (const issue of res.error.issues) {
    const it = toIssue(issue.path, issue.message);
    const id = `${it.field}|${it.message}`;
    if (!seen.has(id)) {
      seen.add(id);
      out.push(it);
    }
  }
  return out;
}

/** Extra checks save_campaign runs only with p_submit = true. */
export function submitIssues(draft: CampaignDraft, now: Date = new Date()): DraftIssue[] {
  const out: DraftIssue[] = [];
  if (draft.is_template) out.push({ step: 'summary', field: 'is_template', message: 'errors.templateSubmit' });
  if (!draft.start_at) out.push({ step: 'schedule', field: 'start_at', message: 'errors.startRequired' });
  if (!draft.submit_deadline) out.push({ step: 'schedule', field: 'submit_deadline', message: 'errors.deadlineRequired' });
  else if (Date.parse(draft.submit_deadline) <= now.getTime()) {
    out.push({ step: 'schedule', field: 'submit_deadline', message: 'errors.deadlinePast' });
  }
  if (draft.pools.length === 0) out.push({ step: 'rewards', field: 'pools', message: 'errors.poolsRequired' });
  draft.pools.forEach((p, i) => {
    if (!draft.rules.some((r) => r.pool === p.key)) out.push({ step: 'rewards', field: `pools.${i}`, message: 'errors.poolNeedsRule' });
  });
  return out;
}

export function draftIssues(draft: CampaignDraft, opts: { submit?: boolean; now?: Date } = {}): DraftIssue[] {
  const issues = schemaIssues(draft);
  return opts.submit ? [...issues, ...submitIssues(draft, opts.now)] : issues;
}

export function isPoolOrRuleIssue(issue: Pick<DraftIssue, 'field'>): boolean {
  return issue.field === 'pools' || issue.field === 'rules' || issue.field.startsWith('pools.') || issue.field.startsWith('rules.');
}

/** Pools + rules complete and valid → they can be sent (otherwise save_campaign would reject the whole save). */
export function poolsReady(draft: CampaignDraft): boolean {
  return !schemaIssues(draft).some(isPoolOrRuleIssue);
}
