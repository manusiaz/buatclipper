import { describe, expect, it } from 'vitest';
import { channelsFrom, segmentFrom } from './segment';

const form = (o: Record<string, string>) => (k: string) => o[k] ?? null;

describe('segmentFrom', () => {
  it('empty form = everyone', () => {
    expect(segmentFrom(form({}))).toEqual({});
  });
  it('only keys accepted by api.send_broadcast', () => {
    expect(
      segmentFrom(form({ platform_tiktok: 'on', platform_youtube: 'on', min_trust_score: '60', max_trust_score: '', kyc: 'approved', active_days: '14' })),
    ).toEqual({ platforms: ['tiktok', 'youtube'], min_trust_score: 60, kyc: 'approved', active_days: 14 });
  });
  it('drops out-of-range and unknown values', () => {
    expect(segmentFrom(form({ min_trust_score: '120', kyc: 'any', active_days: '0' }))).toEqual({});
  });
  it('channels', () => {
    expect(channelsFrom(form({ channel_in_app: 'on', channel_push: 'on' }))).toEqual(['in_app', 'push']);
  });
});
