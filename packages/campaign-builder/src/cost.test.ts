import { describe, expect, it } from 'vitest';
import { capInViews, costSummary, estimatePoolViews } from './cost';
import { RT_DM, RT_IDR, ctx, validDraft } from './test-fixtures';

describe('costSummary (mirror of finance.issue_invoice)', () => {
  it('PRD §5.2: budget Rp10.000.000 → mgmt 1.500.000, admin 500.000, tax 11% of fees 220.000, total 12.220.000', () => {
    const s = costSummary(validDraft(), ctx);
    expect(s).toMatchObject({
      budgetIdr: 10_000_000,
      mgmtFee: 1_500_000,
      adminFee: 500_000,
      serviceFee: 0,
      tax: 220_000,
      total: 12_220_000,
      mgmtFeePct: 15,
      adminFeePct: 5,
      taxPct: 11,
    });
    expect(s.perPool).toHaveLength(1);
    expect(s.perPool[0]).toMatchObject({ code: 'IDR', total: 10_000_000, budgetIdr: 10_000_000 });
  });

  it('PRD §5.2: Rp2.000 per 1.000 views → 5.000.000 paid views', () => {
    const s = costSummary(validDraft(), ctx);
    expect(s.perPool[0]!.est).toEqual({ byPlatform: { tiktok: 5_000_000, instagram: 5_000_000 }, min: 5_000_000, max: 5_000_000 });
  });

  it('managed package adds the managed_service invoice (service fee + its own tax)', () => {
    const s = costSummary(validDraft({ service_mode: 'managed' }), ctx);
    expect(s.serviceFee).toBe(2_500_000);
    expect(s.campaignTax).toBe(220_000);
    expect(s.serviceTax).toBe(275_000);
    expect(s.tax).toBe(495_000);
    expect(s.total).toBe(10_000_000 + 1_500_000 + 500_000 + 2_500_000 + 495_000);
  });

  it('non-cash reward is valued at idr_value_per_unit (fee on Diamonds, §5.2 multi-reward)', () => {
    const d = validDraft({
      pools: [
        { key: 'idr', id: null, reward_type_id: RT_IDR, total: 20_000_000, max_per_clip: 1_000_000 },
        { key: 'dm', id: null, reward_type_id: RT_DM, total: 50_000, max_per_clip: 2_000 },
      ],
      rules: [
        { key: 'a', kind: 'per_1k_views', pool: 'idr', platform: null, params: { rate: 4000 } },
        { key: 'b', kind: 'per_1k_views', pool: 'dm', platform: null, params: { rate: 8 } },
      ],
    });
    const s = costSummary(d, ctx);
    // Regresi AB-3: invoice menagih pool Rupiah saja (20 jt); Diamonds = stok brand, hanya dasar fee (§5.2, issue_invoice).
    expect(s.budgetIdr).toBe(20_000_000);
    expect(s.nonCashIdr).toBe(12_500_000);
    expect(s.creatorValueIdr).toBe(32_500_000);
    expect(s.mgmtFee).toBe(4_875_000);
    expect(s.adminFee).toBe(1_625_000);
    expect(s.tax).toBe(715_000);
    expect(s.total).toBe(27_215_000);
    expect(s.perPool[1]).toMatchObject({ unit_label: 'Diamonds', total: 50_000, budgetIdr: 12_500_000 });
    // 50.000 Diamonds at 8 / 1.000 views = 6.250.000 views; 20 jt at Rp4.000 = 5.000.000 views
    expect(s.perPool[1]!.est?.max).toBe(6_250_000);
    expect(s.perPool[0]!.est?.max).toBe(5_000_000);
  });

  it('rounds like Postgres round(numeric, 2) — half away from zero, per line', () => {
    const d = validDraft({
      pools: [{ key: 'p', id: null, reward_type_id: 'rt-odd', total: 1, max_per_clip: 1 }],
      rules: [{ key: 'r', kind: 'flat_per_post', pool: 'p', platform: null, params: { amount: 1 } }],
    });
    const odd = { ...ctx, rewardTypes: [...ctx.rewardTypes, { ...ctx.rewardTypes[0]!, id: 'rt-odd', code: 'ODD', idr_value_per_unit: 333.33 }] };
    const s = costSummary(d, odd);
    expect(s.budgetIdr).toBe(0); // non-tunai: tidak ditagih
    expect(s.creatorValueIdr).toBe(333.33);
    expect(s.mgmtFee).toBe(50); // 49.9995 → 50.00
    expect(s.adminFee).toBe(16.67); // 16.6665 → 16.67
    expect(s.tax).toBe(7.33); // 66.67 × 0.11 = 7.3337 → 7.33
    expect(s.total).toBe(74);
  });

  it('no float drift on decimal totals (0.1 + 0.2 style)', () => {
    const d = validDraft({ pools: [{ key: 'p', id: null, reward_type_id: 'rt-dec', total: 0.3, max_per_clip: 0.1 }], rules: [] });
    const dec = { ...ctx, rewardTypes: [{ ...ctx.rewardTypes[0]!, id: 'rt-dec', code: 'DEC', idr_value_per_unit: 0.1, decimals: 2 }] };
    expect(costSummary(d, dec).nonCashIdr).toBe(0.03);
  });

  it('admin fee override (draft.fee = set) wins over the effective fee', () => {
    const s = costSummary(validDraft({ fee: { mode: 'set', source_id: null, mgmt_fee_pct: 10, admin_fee_pct: 2.5 } }), ctx);
    expect(s.mgmtFee).toBe(1_000_000);
    expect(s.adminFee).toBe(250_000);
    expect(s.tax).toBe(137_500);
    expect(s.total).toBe(11_387_500);
  });

  it('unknown reward type counts as Rp0 and is flagged; empty pool total is 0', () => {
    const s = costSummary(validDraft({ pools: [{ key: 'x', id: null, reward_type_id: 'nope', total: null, max_per_clip: null }] }), ctx);
    expect(s.budgetIdr).toBe(0);
    expect(s.total).toBe(0);
    expect(s.perPool[0]!.unknownRewardType).toBe(true);
    expect(s.perPool[0]!.est).toBeNull();
  });
});

describe('estimates', () => {
  it('per-platform rates give a min–max range; platform-less rules apply everywhere and add up', () => {
    const d = validDraft({
      rules: [
        { key: 'a', kind: 'per_1k_views', pool: 'idr', platform: 'tiktok', params: { rate: 2000 } },
        { key: 'b', kind: 'per_1k_views', pool: 'idr', platform: 'instagram', params: { rate: 2500 } },
        { key: 'c', kind: 'tiered_cpm', pool: 'idr', platform: null, params: { tiers: [{ from: 0, to: null, rate: 500 }] } },
        { key: 'd', kind: 'flat_per_post', pool: 'idr', platform: null, params: { amount: 25_000 } },
      ],
    });
    expect(estimatePoolViews(d, 'idr', 10_000_000)).toEqual({
      byPlatform: { tiktok: 4_000_000, instagram: 3_333_333 },
      min: 3_333_333,
      max: 4_000_000,
    });
  });

  it('cap per clip in views', () => {
    expect(capInViews(1_000_000, 4000)).toBe(250_000);
    expect(capInViews(null, 4000)).toBeNull();
    expect(capInViews(1000, 0)).toBeNull();
  });
});
