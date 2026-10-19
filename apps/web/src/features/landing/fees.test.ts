import { describe, expect, it } from 'vitest';
import { brandCost } from './fees';

describe('brandCost', () => {
  it('matches the PRD §5.2 example', () => {
    expect(brandCost(10_000_000)).toEqual({ budget: 10_000_000, mgmt: 1_500_000, admin: 500_000, total: 12_000_000 });
  });
  it('accepts custom percentages', () => {
    expect(brandCost(1_000_000, 10, 2.5)).toEqual({ budget: 1_000_000, mgmt: 100_000, admin: 25_000, total: 1_125_000 });
  });
});
