import { describe, expect, it } from 'vitest';
import { lowProjection, parseStats } from './stats';

describe('parseStats', () => {
  it('tolerates empty / malformed input', () => {
    const s = parseStats(null);
    expect(s.viewsValid).toBe(0);
    expect(s.pools).toEqual([]);
    expect(s.projection.projectedUtilizationPct).toBeNull();
  });
  it('reads numbers given as numeric strings', () => {
    const s = parseStats({
      views_valid: '1200000',
      by_platform: { tiktok: 900000, youtube: '300000', x: 'nope' },
      pools: [{ pool_id: 'p', code: 'IDR', total: '10000000', allocated: 2500000.5, remaining: 7499999.5, est_remaining_views: { tiktok: 10 } }],
      daily: [{ day: '2026-10-01', views: 5 }, { views: 3 }],
      projection: { projected_utilization_pct: 42.5, elapsed_days: 3 },
    });
    expect(s.viewsValid).toBe(1_200_000);
    expect(s.byPlatform).toEqual({ tiktok: 900000, youtube: 300000 });
    expect(s.pools[0]!.allocated).toBe(2500000.5);
    expect(s.daily).toHaveLength(1);
    expect(lowProjection(s, 'live')).toBe(true);
    expect(lowProjection(s, 'paused')).toBe(false);
  });
});
