import { describe, expect, it } from 'vitest';
import { num, publicSettings } from './settings';

describe('num', () => {
  it('parses numbers and numeric strings only', () => {
    expect(num(5)).toBe(5);
    expect(num('100000')).toBe(100000);
    expect(num('2.5')).toBe(2.5);
    expect(num('1e3')).toBeNull();
    expect(num(Number.NaN)).toBeNull();
    expect(num(null)).toBeNull();
    expect(num({})).toBeNull();
  });
});

describe('publicSettings', () => {
  it('falls back to PRD defaults', () => {
    expect(publicSettings([])).toEqual({
      minWithdrawIdr: 100000,
      managedServiceIdr: null,
      maxAccountsPerPlatform: 3,
      claimHours: 48,
      platforms: ['tiktok', 'instagram', 'youtube'],
    });
  });
  it('reads values and enabled platform flags', () => {
    const s = publicSettings([
      { key: 'public.finance.min_withdraw_idr', value: 50000 },
      { key: 'public.billing.managed_service_idr', value: '2500000' },
      { key: 'public.market.max_accounts_per_platform', value: 2 },
      { key: 'public.market.claim_hours', value: '24' },
      { key: 'public.flags.platforms', value: { tiktok: true, instagram: false, youtube: true, threads: true } },
    ]);
    expect(s).toEqual({ minWithdrawIdr: 50000, managedServiceIdr: 2500000, maxAccountsPerPlatform: 2, claimHours: 24, platforms: ['tiktok', 'youtube', 'threads'] });
  });
});
