import { describe, expect, it } from 'vitest';
import { costSummary } from './cost';
import { draftFromDetail } from './detail';
import { baseRateMode } from './model';
import { toSavePayload } from './payload';
import { schemaIssues } from './schema';
import { CAMPAIGN, ORG, RT_DM, RT_IDR, ctx } from './test-fixtures';

const POOL_IDR = '66666666-0000-0000-0000-000000000001';
const POOL_DM = '66666666-0000-0000-0000-000000000002';

/** Shape of api.campaign_detail(p_campaign) (api/read_models.sql + market.campaign_budget). */
const detail = {
  campaign: {
    id: CAMPAIGN,
    org_id: ORG,
    slug: 'film-baru-rilis-a1b2c3',
    title: 'Film Baru Rilis',
    type: 'clipping',
    category_id: 'games',
    status: 'draft',
    platforms: ['instagram', 'tiktok'],
    brief: 'Potong **adegan** terbaik.',
    required_hashtags: ['mplid', 'clipper'],
    required_mentions: ['studiosatu'],
    required_links: ['https://studio.id/promo'],
    sponsored_label: true,
    min_duration_sec: 15,
    max_duration_sec: 60,
    dos: ['Pakai subtitle'],
    donts: ['Jangan reupload utuh'],
    example_urls: ['https://www.tiktok.com/@a/video/1'],
    faq: [{ q: 'Boleh musik?', a: 'Bebas lisensi' }],
    service_mode: 'managed',
    start_at: '2099-01-01T03:00:00+00:00',
    submit_deadline: '2099-01-15T03:00:00+00:00',
    view_window_days: 30,
    review_mode: 'brand',
    min_followers: 500,
    min_account_age_days: 30,
    min_trust_score: 40,
    kyc_required: true,
    min_views: 1000,
    max_clips_per_clipper: 5,
    clipper_quota: 100,
    allow_video_reuse: false,
    visibility: 'level',
    is_template: false,
    pinned_until: null,
    pinned_rank: null,
    created_at: '2026-10-19T03:00:00+00:00',
  },
  // campaign_budget orders pools by code: MLBB_DIAMOND before… no — 'IDR' < 'MLBB_DIAMOND'; put DM first to prove reordering.
  pools: [
    { pool_id: POOL_DM, reward_type_id: RT_DM, code: 'MLBB_DIAMOND', unit_label: 'Diamonds', decimals: 0, idr_value_per_unit: 250, total: 50000, allocated: 0, remaining: 50000, max_per_clip: 2000, est_remaining_views: {} },
    { pool_id: POOL_IDR, reward_type_id: RT_IDR, code: 'IDR', unit_label: 'Rp', decimals: 0, idr_value_per_unit: 1, total: 20000000, allocated: 0, remaining: 20000000, max_per_clip: 1000000, est_remaining_views: {} },
  ],
  rules: [
    { rule_id: 'r-1', kind: 'per_1k_views', platform: 'tiktok', reward_type_id: RT_IDR, code: 'IDR', unit_label: 'Rp', decimals: 0, pool_id: POOL_IDR, params: { rate: 4000 }, effective_from: '2026-10-19T03:00:00+00:00' },
    { rule_id: 'r-2', kind: 'per_1k_views', platform: 'instagram', reward_type_id: RT_IDR, code: 'IDR', unit_label: 'Rp', decimals: 0, pool_id: POOL_IDR, params: { rate: 3000 }, effective_from: '2026-10-19T03:00:00+00:00' },
    { rule_id: 'r-3', kind: 'tiered_cpm', platform: null, reward_type_id: RT_DM, code: 'MLBB_DIAMOND', unit_label: 'Diamonds', decimals: 0, pool_id: POOL_DM, params: { tiers: [{ from: 0, to: 50000, rate: 8 }, { from: 50000, rate: 6 }] }, effective_from: '2026-10-19T03:00:00+00:00' },
  ],
  budget_idr: 32500000,
  remaining_idr: 32500000,
  est_remaining_views: {},
  assets: [
    { id: 'a-cover', kind: 'cover', audience: 'clipper', url: null, size_bytes: 120000, storage_path: `${ORG}/${CAMPAIGN}/cover.webp`, bucket: 'campaign-covers' },
    { id: 'a-link', kind: 'link', audience: 'clipper', url: 'https://drive.example/folder', size_bytes: null, storage_path: null, bucket: null },
    { id: 'a-int', kind: 'document', audience: 'internal', url: null, size_bytes: 5000, storage_path: `${ORG}/${CAMPAIGN}/internal/brief.pdf`, bucket: 'campaign-assets' },
  ],
  my: { claim: null, submissions: [], clips_used: 0 },
  cta_state: null,
  cta_reason: null,
};

describe('draftFromDetail', () => {
  it('maps api.campaign_detail into the draft (IDR pool first, assets split by kind/audience)', () => {
    const d = draftFromDetail(detail);
    expect(d.id).toBe(CAMPAIGN);
    expect(d.org_id).toBe(ORG);
    expect(d.platforms).toEqual(['tiktok', 'instagram']);
    expect(d.pools.map((p) => p.id)).toEqual([POOL_IDR, POOL_DM]);
    expect(d.rules.map((r) => [r.key, r.pool, r.platform])).toEqual([
      ['r-1', POOL_IDR, 'tiktok'],
      ['r-2', POOL_IDR, 'instagram'],
      ['r-3', POOL_DM, null],
    ]);
    expect(d.rules[2]!.params.tiers).toEqual([
      { from: 0, to: 50000, rate: 8 },
      { from: 50000, to: null, rate: 6 },
    ]);
    expect(d.cover?.storage_path).toBe(`${ORG}/${CAMPAIGN}/cover.webp`);
    expect(d.assets.map((a) => a.kind)).toEqual(['link']);
    expect(d.internal_files.map((a) => a.name)).toEqual(['brief.pdf']);
    expect(d.fee).toEqual({ mode: 'keep' });
    expect(baseRateMode(d)).toBe('per_platform');
    expect(schemaIssues(d)).toEqual([]);
  });

  it('round-trips: draftFromDetail → toSavePayload reproduces the stored campaign', () => {
    const p = toSavePayload(draftFromDetail(detail));
    const c = detail.campaign;
    expect(p).toMatchObject({
      id: CAMPAIGN,
      slug: c.slug,
      title: c.title,
      type: c.type,
      category_id: c.category_id,
      brief: c.brief,
      required_hashtags: c.required_hashtags,
      required_mentions: c.required_mentions,
      required_links: c.required_links,
      example_urls: c.example_urls,
      dos: c.dos,
      donts: c.donts,
      faq: c.faq,
      sponsored_label: c.sponsored_label,
      min_duration_sec: 15,
      max_duration_sec: 60,
      service_mode: 'managed',
      start_at: c.start_at,
      submit_deadline: c.submit_deadline,
      view_window_days: 30,
      review_mode: 'brand',
      min_followers: 500,
      min_account_age_days: 30,
      min_trust_score: 40,
      kyc_required: true,
      min_views: 1000,
      max_clips_per_clipper: 5,
      clipper_quota: 100,
      allow_video_reuse: false,
      visibility: 'level',
      is_template: false,
    });
    expect(p.pools).toEqual([
      { id: POOL_IDR, key: POOL_IDR, reward_type_id: RT_IDR, total: 20000000, max_per_clip: 1000000 },
      { id: POOL_DM, key: POOL_DM, reward_type_id: RT_DM, total: 50000, max_per_clip: 2000 },
    ]);
    expect(p.rules).toEqual([
      { kind: 'per_1k_views', pool: POOL_IDR, platform: 'tiktok', params: { rate: 4000 } },
      { kind: 'per_1k_views', pool: POOL_IDR, platform: 'instagram', params: { rate: 3000 } },
      { kind: 'tiered_cpm', pool: POOL_DM, params: { tiers: [{ from: 0, to: 50000, rate: 8 }, { from: 50000, rate: 6 }] } },
    ]);
    expect(p.assets).toEqual([
      { kind: 'cover', storage_path: `${ORG}/${CAMPAIGN}/cover.webp`, audience: 'clipper', size_bytes: 120000 },
      { kind: 'link', url: 'https://drive.example/folder', audience: 'clipper' },
      { kind: 'document', storage_path: `${ORG}/${CAMPAIGN}/internal/brief.pdf`, audience: 'internal', size_bytes: 5000 },
    ]);
    // Same budget as the read model.
    expect(costSummary(draftFromDetail(detail), ctx).creatorValueIdr).toBe(detail.budget_idr);
    // Second pass is stable.
    expect(toSavePayload(draftFromDetail(detail))).toEqual(p);
  });

  it('submitted campaigns load locked: payload is {id, faq}', () => {
    const d = draftFromDetail({ ...detail, campaign: { ...detail.campaign, status: 'in_review' } });
    expect(toSavePayload(d)).toEqual({ id: CAMPAIGN, faq: [{ q: 'Boleh musik?', a: 'Bebas lisensi' }] });
  });

  it('tolerates numeric strings and missing optional parts; rejects non-detail input', () => {
    const d = draftFromDetail({ campaign: { id: CAMPAIGN, org_id: ORG, title: 'X', min_views: '2500', platforms: ['tiktok', 'myspace'] } });
    expect(d.min_views).toBe(2500);
    expect(d.platforms).toEqual(['tiktok']);
    expect(d.pools).toEqual([]);
    expect(d.max_clips_per_clipper).toBe(10);
    expect(() => draftFromDetail(null)).toThrow();
    expect(() => draftFromDetail({ campaign: {} })).toThrow();
  });
});
