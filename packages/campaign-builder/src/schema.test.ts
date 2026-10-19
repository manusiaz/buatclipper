import { describe, expect, it } from 'vitest';
import { campaignDraftSchema, fieldStep, poolsReady, schemaIssues, submitIssues } from './schema';
import { CAMPAIGN, ORG, validDraft } from './test-fixtures';
import type { CampaignDraft } from './types';

const messages = (d: CampaignDraft) => schemaIssues(d).map((i) => `${i.field}:${i.message}`);

describe('campaignDraftSchema mirrors the SQL CHECKs', () => {
  it('a complete draft is valid and submittable', () => {
    expect(campaignDraftSchema.safeParse(validDraft()).success).toBe(true);
    expect(submitIssues(validDraft(), new Date('2026-10-19T00:00:00Z'))).toEqual([]);
  });

  it('title 3–120 characters after trim (campaigns.title CHECK char_length)', () => {
    expect(messages(validDraft({ title: '  ab  ' }))).toContain('title:errors.titleLength');
    expect(messages(validDraft({ title: 'abc' }))).not.toContain('title:errors.titleLength');
    expect(messages(validDraft({ title: 'x'.repeat(120) }))).toEqual([]);
    expect(messages(validDraft({ title: 'x'.repeat(121) }))).toContain('title:errors.titleLength');
    // counts code points like char_length (emoji = 1)
    expect(messages(validDraft({ title: '🎬🎬🎬' }))).toEqual([]);
  });

  it('slug optional; when set ^[a-z0-9-]{3,80}$ (lowercased)', () => {
    expect(messages(validDraft({ slug: '' }))).toEqual([]);
    expect(messages(validDraft({ slug: 'Film-Satu' }))).toEqual([]);
    expect(messages(validDraft({ slug: 'ab' }))).toContain('slug:errors.slugFormat');
    expect(messages(validDraft({ slug: 'film satu' }))).toContain('slug:errors.slugFormat');
  });

  it('platforms ≥ 1', () => {
    expect(messages(validDraft({ platforms: [], rules: [] }))).toContain('platforms:errors.platformsRequired');
  });

  it('hashtag / mention / link formats (norm_list + campaigns_*_format)', () => {
    expect(messages(validDraft({ required_hashtags: ['#MPL ID'] }))).toContain('required_hashtags.0:errors.hashtag');
    expect(messages(validDraft({ required_hashtags: ['#MPLID', 'kopi_é'] }))).toEqual([]);
    expect(messages(validDraft({ required_mentions: ['@studio-satu'] }))).toContain('required_mentions.0:errors.mention');
    expect(messages(validDraft({ required_mentions: ['@Studio.Satu_1'] }))).toEqual([]);
    expect(messages(validDraft({ required_links: ['http://studio.id'] }))).toContain('required_links.0:errors.linkHttps');
    expect(messages(validDraft({ required_links: ['studio.id/promo'] }))).toEqual([]);
    expect(messages(validDraft({ example_urls: ['ftp://x'] }))).toContain('example_urls.0:errors.linkHttps');
  });

  it('duration > 0 and min ≤ max', () => {
    expect(messages(validDraft({ min_duration_sec: 0 }))).toContain('min_duration_sec:errors.durationPositive');
    expect(messages(validDraft({ min_duration_sec: 60, max_duration_sec: 15 }))).toContain('max_duration_sec:errors.durationRange');
    expect(messages(validDraft({ min_duration_sec: 15, max_duration_sec: 15 }))).toEqual([]);
    expect(messages(validDraft({ max_duration_sec: 40000 }))).toContain('max_duration_sec:errors.tooLarge');
  });

  it('numeric bounds: view window 1–90, trust 0–100, min_views ≥ 0, max clips ≥ 1, quota ≥ 1 or null', () => {
    expect(messages(validDraft({ view_window_days: 0 }))).toContain('view_window_days:errors.viewWindowRange');
    expect(messages(validDraft({ view_window_days: 91 }))).toContain('view_window_days:errors.viewWindowRange');
    expect(messages(validDraft({ view_window_days: 90 }))).toEqual([]);
    expect(messages(validDraft({ min_trust_score: 101 }))).toContain('min_trust_score:errors.trustRange');
    expect(messages(validDraft({ min_views: -1 }))).toContain('min_views:errors.nonNegative');
    expect(messages(validDraft({ min_views: 0 }))).toEqual([]);
    expect(messages(validDraft({ max_clips_per_clipper: 0 }))).toContain('max_clips_per_clipper:errors.minOne');
    expect(messages(validDraft({ clipper_quota: 0 }))).toContain('clipper_quota:errors.minOne');
    expect(messages(validDraft({ clipper_quota: null }))).toEqual([]);
    expect(messages(validDraft({ min_followers: 1.5 }))).toContain('min_followers:errors.integer');
    expect(messages(validDraft({ min_views: null }))).toContain('min_views:errors.required');
  });

  it('visibility level needs min_trust_score > 0 (campaigns_level_has_threshold)', () => {
    expect(messages(validDraft({ visibility: 'level', min_trust_score: 0 }))).toContain('min_trust_score:errors.levelNeedsTrust');
    expect(messages(validDraft({ visibility: 'level', min_trust_score: 60 }))).toEqual([]);
  });

  it('schedule: submit_deadline > start_at (campaigns_schedule)', () => {
    const at = '2099-01-01T03:00:00.000Z';
    expect(messages(validDraft({ start_at: at, submit_deadline: at }))).toContain('submit_deadline:errors.scheduleOrder');
  });

  it('FAQ rows need both question and answer', () => {
    expect(messages(validDraft({ faq: [{ q: '', a: 'jawab' }] }))).toContain('faq.0.q:errors.faqQuestion');
    expect(messages(validDraft({ faq: [{ q: 'tanya', a: ' ' }] }))).toContain('faq.0.a:errors.faqAnswer');
    expect(messages(validDraft({ faq: [{ q: '', a: '' }] }))).toEqual([]);
  });

  it('pools: total > 0, max_per_clip > 0, reward type set', () => {
    const d = validDraft({ pools: [{ key: 'idr', id: null, reward_type_id: '', total: 0, max_per_clip: null }] });
    expect(messages(d)).toEqual(
      expect.arrayContaining(['pools.0.reward_type_id:errors.rewardTypeRequired', 'pools.0.total:errors.positive', 'pools.0.max_per_clip:errors.required']),
    );
    expect(poolsReady(d)).toBe(false);
  });

  it('rule params per kind (market.check_rule_params)', () => {
    const rule = (params: object, kind: CampaignDraft['rules'][number]['kind']) =>
      messages(validDraft({ rules: [{ key: 'r', kind, pool: 'idr', platform: null, params }] }));
    expect(rule({ rate: 0 }, 'per_1k_views')).toContain('rules.0.params.rate:errors.ruleRate');
    expect(rule({ amount: null }, 'flat_per_post')).toContain('rules.0.params.amount:errors.ruleAmount');
    expect(rule({ threshold: 0, amount: 5 }, 'milestone_bonus')).toContain('rules.0.params.threshold:errors.ruleThreshold');
    expect(rule({ tiers: [] }, 'tiered_cpm')).toContain('rules.0.params.tiers:errors.tiersRequired');
    expect(rule({ tiers: [{ from: 10, to: null, rate: 1 }] }, 'tiered_cpm')).toContain('rules.0.params.tiers.0.from:errors.tierStart');
    expect(rule({ tiers: [{ from: 0, to: 0, rate: 1 }] }, 'tiered_cpm')).toContain('rules.0.params.tiers.0.to:errors.tierTo');
    expect(rule({ tiers: [{ from: 0, to: null, rate: 2 }, { from: 50, to: null, rate: 1 }] }, 'tiered_cpm')).toContain(
      'rules.0.params.tiers.0.to:errors.tierOpenLast',
    );
    expect(rule({ tiers: [{ from: 0, to: 100, rate: 2 }, { from: 50, to: null, rate: 1 }] }, 'tiered_cpm')).toContain(
      'rules.0.params.tiers.1.from:errors.tierGap',
    );
    expect(rule({ tiers: [{ from: 0, to: 50_000, rate: 2000 }, { from: 50_000, to: null, rate: 1500 }] }, 'tiered_cpm')).toEqual([]);
  });

  it('rule platform must be a campaign platform; rule must point to a pool of this draft', () => {
    expect(messages(validDraft({ rules: [{ key: 'r', kind: 'per_1k_views', pool: 'idr', platform: 'youtube', params: { rate: 1 } }] }))).toContain(
      'rules.0.platform:errors.rulePlatform',
    );
    expect(messages(validDraft({ rules: [{ key: 'r', kind: 'per_1k_views', pool: 'ghost', platform: null, params: { rate: 1 } }] }))).toContain(
      'rules.0.pool:errors.rulePool',
    );
  });

  it('assets: one source, https links, internal/ folder ⇔ audience internal', () => {
    const base = `${ORG}/${CAMPAIGN}/`;
    expect(
      messages(validDraft({ assets: [{ key: 'a', id: null, kind: 'link', audience: 'clipper', storage_path: null, url: 'http://x.id', size_bytes: null, name: null }] })),
    ).toContain('assets.0:errors.linkHttps');
    expect(
      messages(
        validDraft({
          internal_files: [{ key: 'a', id: null, kind: 'document', audience: 'internal', storage_path: `${base}brief.pdf`, url: null, size_bytes: null, name: null }],
        }),
      ),
    ).toContain('internal_files.0:errors.assetFolder');
    expect(
      messages(validDraft({ assets: [{ key: 'a', id: null, kind: 'video', audience: 'clipper', storage_path: `${base}a.mp4`, url: 'https://x', size_bytes: null, name: null }] })),
    ).toContain('assets.0:errors.assetSource');
  });

  it('reports every problem at once even when a field has the wrong type', () => {
    const issues = messages(validDraft({ min_views: null, title: 'a', min_duration_sec: 9, max_duration_sec: 3 }));
    expect(issues).toEqual(expect.arrayContaining(['min_views:errors.required', 'title:errors.titleLength', 'max_duration_sec:errors.durationRange']));
  });
});

describe('submitIssues (checks save_campaign runs with p_submit)', () => {
  const now = new Date('2026-10-19T00:00:00Z');
  it('needs schedule, a future deadline, ≥ 1 pool and a rule per pool; templates cannot be submitted', () => {
    const fields = (d: CampaignDraft) => submitIssues(d, now).map((i) => `${i.step}/${i.field}:${i.message}`);
    expect(fields(validDraft({ start_at: null, submit_deadline: null }))).toEqual([
      'schedule/start_at:errors.startRequired',
      'schedule/submit_deadline:errors.deadlineRequired',
    ]);
    expect(fields(validDraft({ submit_deadline: '2026-10-18T00:00:00Z', start_at: '2026-10-01T00:00:00Z' }))).toEqual([
      'schedule/submit_deadline:errors.deadlinePast',
    ]);
    expect(fields(validDraft({ pools: [], rules: [] }))).toEqual(['rewards/pools:errors.poolsRequired']);
    expect(fields(validDraft({ rules: [] }))).toEqual(['rewards/pools.0:errors.poolNeedsRule']);
    expect(fields(validDraft({ is_template: true }))).toEqual(['summary/is_template:errors.templateSubmit']);
  });
});

describe('fieldStep', () => {
  it('maps field paths to wizard steps', () => {
    expect(fieldStep(['title'])).toBe('basics');
    expect(fieldStep(['required_hashtags', 2])).toBe('brief');
    expect(fieldStep(['platforms'])).toBe('platforms');
    expect(fieldStep(['pools', 0, 'reward_type_id'])).toBe('rewards');
    expect(fieldStep(['pools', 0, 'total'])).toBe('budget');
    expect(fieldStep(['rules', 1, 'params', 'rate'])).toBe('rewards');
    expect(fieldStep(['min_trust_score'])).toBe('eligibility');
    expect(fieldStep(['submit_deadline'])).toBe('schedule');
    expect(fieldStep(['fee'])).toBe('summary');
  });
});
