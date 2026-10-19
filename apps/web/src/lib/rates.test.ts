import { describe, expect, it } from 'vitest';
import { estRemainingViews, idrRates, maxViews, parseRule, rateGroups, ruleRate, rulesFromJson, type Rule } from './rates';

const rule = (r: Partial<Rule>): Rule => ({
  kind: 'per_1k_views',
  platform: null,
  params: { rate: 2000 },
  code: 'IDR',
  unit_label: 'Rp',
  decimals: 0,
  pool_id: 'p1',
  ...r,
});

describe('parseRule', () => {
  it('parses every kind', () => {
    expect(parseRule('per_1k_views', { rate: '2000' })).toEqual({ kind: 'per_1k_views', rate: 2000 });
    expect(parseRule('flat_per_post', { amount: 25000 })).toEqual({ kind: 'flat_per_post', amount: 25000 });
    expect(parseRule('milestone_bonus', { threshold: 100000, amount: 50000 })).toEqual({
      kind: 'milestone_bonus',
      threshold: 100000,
      amount: 50000,
    });
    expect(parseRule('tiered_cpm', { tiers: [{ from: 0, to: 50000, rate: 2000 }, { from: 50000, rate: 1500 }] })).toEqual({
      kind: 'tiered_cpm',
      tiers: [
        { from: 0, to: 50000, rate: 2000 },
        { from: 50000, to: null, rate: 1500 },
      ],
    });
  });
  it('rejects broken params and unknown kinds', () => {
    expect(parseRule('per_1k_views', {})).toBeNull();
    expect(parseRule('milestone_bonus', { amount: 1 })).toBeNull();
    expect(parseRule('tiered_cpm', { tiers: [] })).toBeNull();
    expect(parseRule('mystery', { rate: 1 })).toBeNull();
    expect(parseRule('per_1k_views', null)).toBeNull();
  });
});

describe('ruleRate', () => {
  it('mirrors market.rule_rate', () => {
    expect(ruleRate('per_1k_views', { rate: 4000 })).toBe(4000);
    expect(ruleRate('tiered_cpm', { tiers: [{ from: 0, rate: 2000 }, { from: 5, rate: 1 }] })).toBe(2000);
    expect(ruleRate('flat_per_post', { amount: 25000 })).toBeNull();
  });
});

describe('idrRates', () => {
  it('stacks IDR rules per platform and skips other reward types', () => {
    const rules = [
      rule({}),
      rule({ platform: 'tiktok', params: { rate: 1000 } }),
      rule({ code: 'DIAMOND', params: { rate: 8 } }),
      rule({ kind: 'flat_per_post', params: { amount: 25000 } }),
    ];
    expect(idrRates(rules, ['tiktok', 'instagram'])).toEqual([
      { platform: 'tiktok', ratePer1k: 3000 },
      { platform: 'instagram', ratePer1k: 2000 },
    ]);
  });
  it('drops platforms without a views rate', () => {
    expect(idrRates([rule({ platform: 'youtube' })], ['tiktok'])).toEqual([]);
  });
});

describe('rulesFromJson', () => {
  it('reads list_campaigns rates jsonb defensively', () => {
    expect(rulesFromJson([{ kind: 'per_1k_views', platform: 'tiktok', params: { rate: 1 }, code: 'IDR', decimals: '0' }, 'x'])).toEqual([
      { kind: 'per_1k_views', platform: 'tiktok', params: { rate: 1 }, code: 'IDR', unit_label: null, decimals: 0, pool_id: null },
      { kind: '', platform: null, params: undefined, code: null, unit_label: null, decimals: null, pool_id: null },
    ]);
    expect(rulesFromJson(null)).toEqual([]);
  });
});

describe('maxViews', () => {
  it('takes the largest platform estimate', () => {
    expect(maxViews({ tiktok: 5000000, instagram: '2500000' })).toBe(5000000);
    expect(maxViews({})).toBeNull();
    expect(maxViews(null)).toBeNull();
  });
});

describe('estRemainingViews', () => {
  it('matches campaign_budget: remaining × 1000 ÷ summed rate, best pool/platform', () => {
    const rules = [rule({}), rule({ platform: 'tiktok', params: { rate: 2000 } })];
    // tiktok: 10jt*1000/4000 = 2,5jt; instagram: 10jt*1000/2000 = 5jt
    expect(estRemainingViews([{ id: 'p1', remaining: 10_000_000 }], rules, ['tiktok', 'instagram'])).toBe(5_000_000);
  });
  it('is null without per-views rules and never negative', () => {
    expect(estRemainingViews([{ id: 'p1', remaining: 100 }], [rule({ kind: 'flat_per_post', params: { amount: 1 } })], ['tiktok'])).toBeNull();
    expect(estRemainingViews([{ id: 'p1', remaining: -5 }], [rule({})], ['tiktok'])).toBe(0);
  });
});

describe('rateGroups', () => {
  it('merges platforms that share the same rules', () => {
    const all = rule({});
    const tt = rule({ platform: 'tiktok', params: { rate: 500 } });
    const groups = rateGroups([all, tt], ['tiktok', 'instagram', 'youtube']);
    expect(groups).toEqual([
      { platforms: ['tiktok'], rules: [all, tt] },
      { platforms: ['instagram', 'youtube'], rules: [all] },
    ]);
  });
  it('skips platforms without rules', () => {
    expect(rateGroups([rule({ platform: 'tiktok' })], ['instagram'])).toEqual([]);
  });
});
