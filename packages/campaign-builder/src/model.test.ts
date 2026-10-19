import { describe, expect, it } from 'vitest';
import { fromWibInput, toWibInput } from './datetime';
import { baseRateMode, baseRules, earningForViews, newDraft, setBaseRate, setBaseRateMode, togglePlatform } from './model';
import { RT_IDR, ctx } from './test-fixtures';

describe('newDraft', () => {
  it('starts from the column defaults with an IDR pool and a CPM rule on the enabled platforms', () => {
    const d = newDraft(ctx);
    expect(d).toMatchObject({
      id: null,
      org_id: ctx.org.id,
      status: 'draft',
      type: 'clipping',
      platforms: ['tiktok', 'instagram', 'youtube'],
      min_views: 1000,
      max_clips_per_clipper: 10,
      view_window_days: 30,
      review_mode: 'manual',
      visibility: 'public',
      sponsored_label: true,
      service_mode: 'self_serve',
      fee: { mode: 'keep' },
    });
    expect(d.pools).toHaveLength(1);
    expect(d.pools[0]!.reward_type_id).toBe(RT_IDR);
    expect(baseRateMode(d)).toBe('same');
  });
});

describe('step 3 rate per platform', () => {
  it('same ↔ per-platform keeps rates; platform toggles add/remove per-platform rules', () => {
    let d = setBaseRate(newDraft(ctx), null, 2000);
    d = setBaseRateMode(d, 'per_platform');
    expect(baseRateMode(d)).toBe('per_platform');
    expect(baseRules(d).map((r) => [r.platform, r.params.rate])).toEqual([
      ['tiktok', 2000],
      ['instagram', 2000],
      ['youtube', 2000],
    ]);
    d = setBaseRate(d, 'instagram', 2500);
    d = togglePlatform(d, 'youtube', false);
    expect(d.platforms).toEqual(['tiktok', 'instagram']);
    expect(baseRules(d).map((r) => r.platform)).toEqual(['tiktok', 'instagram']);
    d = togglePlatform(d, 'youtube', true);
    expect(baseRules(d).map((r) => [r.platform, r.params.rate])).toEqual([
      ['tiktok', 2000],
      ['instagram', 2500],
      ['youtube', 2000],
    ]);
    d = setBaseRateMode(d, 'same');
    expect(baseRules(d)).toHaveLength(1);
    expect(baseRules(d)[0]).toMatchObject({ platform: null, params: { rate: 2000 } });
  });

  it('extra rules on the base pool make the mode custom', () => {
    const d = newDraft(ctx);
    const extra = { ...d, rules: [...d.rules, { key: 'x', kind: 'per_1k_views' as const, pool: d.pools[0]!.key, platform: null, params: { rate: 1 } }] };
    expect(baseRateMode(extra)).toBe('custom');
    expect(baseRateMode({ ...d, rules: [] })).toBe('none');
  });
});

describe('earningForViews', () => {
  it('per kind, tiered marginal like finance.rule_amount', () => {
    expect(earningForViews({ kind: 'per_1k_views', params: { rate: 2000 } }, 10_000)).toBe(20_000);
    const tiered = { kind: 'tiered_cpm' as const, params: { tiers: [{ from: 0, to: 50_000, rate: 2000 }, { from: 50_000, to: null, rate: 1500 }] } };
    expect(earningForViews(tiered, 60_000)).toBe(115_000);
    expect(earningForViews({ kind: 'flat_per_post', params: { amount: 25_000 } }, 0)).toBe(25_000);
    expect(earningForViews({ kind: 'milestone_bonus', params: { threshold: 100_000, amount: 50_000 } }, 99_999)).toBe(0);
    expect(earningForViews({ kind: 'milestone_bonus', params: { threshold: 100_000, amount: 50_000 } }, 100_000)).toBe(50_000);
  });
});

describe('WIB date inputs', () => {
  it('converts between ISO UTC and datetime-local in WIB (UTC+7)', () => {
    expect(toWibInput('2026-10-20T03:00:00Z')).toBe('2026-10-20T10:00');
    expect(toWibInput('2026-10-20T20:30:00+00:00')).toBe('2026-10-21T03:30');
    expect(fromWibInput('2026-10-20T10:00')).toBe('2026-10-20T03:00:00.000Z');
    expect(fromWibInput('2026-10-21T03:30')).toBe('2026-10-20T20:30:00.000Z');
    expect(fromWibInput('')).toBeNull();
    expect(toWibInput(null)).toBe('');
  });
});
