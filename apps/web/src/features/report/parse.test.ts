import { describe, expect, it } from 'vitest';
import { isReportToken, parseReport } from './parse';

const sample = {
  campaign: { title: 'MPL Clip Week', status: 'live', start_at: '2026-10-01T03:00:00Z', submit_deadline: '2026-10-31T16:59:00Z', platforms: ['tiktok', 'youtube', 'myspace'] },
  views_valid: 1250000,
  clips: 42,
  clippers: 17,
  by_platform: { tiktok: 900000, youtube: '350000', myspace: 5 },
  budget: [
    { reward_type: 'IDR', unit: 'Rp', total: 10000000, spent: '2500000.5' },
    { reward_type: 'DIAMOND', unit: 'Diamonds', decimals: 0, total: 5000, spent: 1200 },
  ],
  top_clips: [
    { url: 'https://www.tiktok.com/@a/video/1234567890', platform: 'tiktok', views: 400000 },
    { url: 'javascript:alert(1)', platform: 'tiktok', views: 1 },
    { url: 'https://youtu.be/abcdefgh', platform: 'unknown', views: 10 },
  ],
  ecpm_idr: '2400.5',
};

describe('parseReport', () => {
  it('parses the campaign_report payload', () => {
    expect(parseReport(sample)).toEqual({
      campaign: { title: 'MPL Clip Week', status: 'live', startAt: '2026-10-01T03:00:00Z', submitDeadline: '2026-10-31T16:59:00Z', platforms: ['tiktok', 'youtube'] },
      viewsValid: 1250000,
      clips: 42,
      clippers: 17,
      byPlatform: [
        { platform: 'tiktok', views: 900000 },
        { platform: 'youtube', views: 350000 },
      ],
      budget: [
        { code: 'IDR', unit: 'Rp', decimals: 0, total: 10000000, spent: 2500000.5 },
        { code: 'DIAMOND', unit: 'Diamonds', decimals: 0, total: 5000, spent: 1200 },
      ],
      topClips: [
        { url: 'https://www.tiktok.com/@a/video/1234567890', platform: 'tiktok', views: 400000 },
        { url: 'https://youtu.be/abcdefgh', platform: null, views: 10 },
      ],
      ecpmIdr: 2400.5,
    });
  });
  it('returns null for an invalid / expired link (null from the RPC)', () => {
    expect(parseReport(null)).toBeNull();
    expect(parseReport({})).toBeNull();
  });
  it('handles an empty campaign', () => {
    const r = parseReport({ campaign: { title: 'X', status: 'scheduled', start_at: null, submit_deadline: null, platforms: [] }, views_valid: 0, clips: 0, clippers: 0, by_platform: {}, budget: [], top_clips: [] });
    expect(r?.viewsValid).toBe(0);
    expect(r?.byPlatform).toEqual([]);
    expect(r?.topClips).toEqual([]);
  });
});

describe('isReportToken', () => {
  it('accepts base64url tokens only', () => {
    expect(isReportToken('A'.repeat(43))).toBe(true);
    expect(isReportToken('aZ09-_'.repeat(7) + 'x')).toBe(true);
    expect(isReportToken('A'.repeat(19))).toBe(false);
    expect(isReportToken('A'.repeat(42) + '=')).toBe(false);
    expect(isReportToken('A'.repeat(42) + '/')).toBe(false);
    expect(isReportToken('A'.repeat(129))).toBe(false);
  });
});
