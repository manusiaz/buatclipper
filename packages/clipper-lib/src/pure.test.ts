import { describe, expect, it } from 'vitest';
import {
  base64UrlToBytes,
  budgetUsedRatio,
  cardRates,
  communityLinks,
  enabledPlatforms,
  errorKey,
  estimateRelease,
  weekStartUtc,
  maxViews,
  sharedUrl,
  assetLinks,
  nextBatchDate,
  recipientFields,
  ruleRate,
  safeEqual,
  taskGroup,
} from './pure';

describe('rates', () => {
  const rules = [
    { kind: 'per_1k_views', platform: null, reward_type_id: 'idr', params: { rate: 2000 } },
    { kind: 'per_1k_views', platform: 'tiktok', reward_type_id: 'dia', params: { rate: 8 } },
    { kind: 'tiered_cpm', platform: 'instagram', reward_type_id: 'idr', params: { tiers: [{ from: 0, rate: 1000 }, { from: 1e5, rate: 500 }] } },
    { kind: 'flat_per_post', platform: null, reward_type_id: 'idr', params: { amount: 5000 } },
  ];
  it('ruleRate = market.rule_rate', () => {
    expect(ruleRate(rules[0]!)).toBe(2000);
    expect(ruleRate(rules[2]!)).toBe(1000);
    expect(ruleRate(rules[3]!)).toBe(0);
  });
  it('cardRates sums rules per platform in IDR', () => {
    const idr = new Map([['idr', 1], ['dia', 250]]);
    expect(cardRates(rules, ['tiktok', 'instagram', 'youtube'], idr)).toEqual([
      { platform: 'tiktok', ratePer1k: 4000 },
      { platform: 'instagram', ratePer1k: 3000 },
      { platform: 'youtube', ratePer1k: 2000 },
    ]);
  });
  it('remaining views & budget ratio', () => {
    expect(maxViews({ tiktok: 5_800_000, instagram: '120' })).toBe(5_800_000);
    expect(maxViews({})).toBeUndefined();
    expect(budgetUsedRatio(1000, 250)).toBe(0.75);
    expect(budgetUsedRatio(0, 0)).toBeUndefined();
  });
});

describe('errorKey', () => {
  it('missing_tags lists every tag from the Edge Function detail', () => {
    expect(errorKey('missing_tags', ['#mplid', '@studio'])).toEqual({ key: 'missing_tags', param: '#mplid, @studio' });
    expect(errorKey('missing_tags:#a,#b')).toEqual({ key: 'missing_tags', param: '#a, #b' });
  });
  it('need_social_account names the platform', () => {
    expect(errorKey('not_eligible:need_social_account:tiktok', undefined, (p) => p.toUpperCase())).toEqual({
      key: 'not_eligible.need_social_account',
      param: 'TIKTOK',
    });
  });
  it('unknown text → generic', () => {
    expect(errorKey('permission denied for table x').key).toBe('generic');
  });
});

describe('misc', () => {
  it('safeEqual', () => {
    expect(safeEqual('abc', 'abc')).toBe(true);
    expect(safeEqual('abc', 'abd')).toBe(false);
    expect(safeEqual('abc', 'abcd')).toBe(false);
    expect(safeEqual('', '')).toBe(false);
  });
  it('community links only https', () => {
    expect(communityLinks({ discord: 'https://discord.gg/x', whatsapp: '', evil: 'javascript:alert(1)' })).toEqual([
      { key: 'discord', href: 'https://discord.gg/x' },
    ]);
  });
  it('enabled platforms keep order', () => {
    expect(enabledPlatforms({ youtube: true, tiktok: true, threads: false })).toEqual(['tiktok', 'youtube']);
  });
  it('release estimate = lock + 7 days', () => {
    const d = estimateRelease({ locked_at: null, posted_at: '2026-10-01T00:00:00Z', created_at: '2026-10-01T00:00:00Z' }, 30);
    expect(d.toISOString()).toBe('2026-11-07T00:00:00.000Z');
    expect(estimateRelease({ locked_at: '2026-10-10T00:00:00Z', posted_at: null, created_at: 'x' }, 30).toISOString()).toBe(
      '2026-10-17T00:00:00.000Z',
    );
  });
  it('next batch = next Monday 10.00 WIB', () => {
    expect(nextBatchDate(new Date('2026-10-19T02:00:00Z')).toISOString()).toBe('2026-10-26T03:00:00.000Z'); // Senin → Senin depan
    expect(nextBatchDate(new Date('2026-10-21T10:00:00Z')).toISOString()).toBe('2026-10-26T03:00:00.000Z');
    expect(nextBatchDate(new Date('2026-10-25T18:00:00Z')).toISOString()).toBe('2026-11-02T03:00:00.000Z'); // Senin 01.00 WIB
  });
  it('recipient fields default required', () => {
    expect(recipientFields([{ key: 'user_id', label: 'User ID' }, { key: 'phone', pii: true, required: false }, { nope: 1 }])).toEqual([
      { key: 'user_id', label: 'User ID', pii: false, required: true },
      { key: 'phone', label: 'phone', pii: true, required: false },
    ]);
  });
  it('task groups', () => {
    expect(['validating', 'in_review', 'flagged', 'rejected_final', 'appealed', 'settled'].map(taskGroup)).toEqual([
      'validating',
      'review',
      'tracking',
      'rejected',
      'appeal',
      'locked',
    ]);
  });
  it('vapid key decode', () => {
    expect([...base64UrlToBytes('AQID_w')]).toEqual([1, 2, 3, 255]);
  });
});

describe('weekStartUtc (AC-5 leaderboard Minggu ini)', () => {
  it('Senin 00:00 UTC minggu berjalan, termasuk saat hari Minggu', () => {
    expect(weekStartUtc(new Date('2026-10-20T03:00:00Z')).toISOString()).toBe('2026-10-19T00:00:00.000Z');
    expect(weekStartUtc(new Date('2026-10-25T23:59:00Z')).toISOString()).toBe('2026-10-19T00:00:00.000Z');
    expect(weekStartUtc(new Date('2026-10-19T00:00:00Z')).toISOString()).toBe('2026-10-19T00:00:00.000Z');
  });
});

describe('sharedUrl (share target PWA)', () => {
  it('ambil link https dari text kalau url kosong', () => {
    expect(sharedUrl({ text: 'Tonton video ini https://vt.tiktok.com/ZSabc123/ keren!' })).toBe('https://vt.tiktok.com/ZSabc123/');
  });
  it('url didahulukan, tanda baca penutup dibuang', () => {
    expect(sharedUrl({ url: 'https://youtu.be/abc).', text: 'https://x.com/a/status/1' })).toBe('https://youtu.be/abc');
  });
  it('http / tanpa link → null', () => {
    expect(sharedUrl({ url: 'http://evil.test/a', text: 'halo', title: undefined })).toBeNull();
    expect(sharedUrl({})).toBeNull();
  });
});

describe('assetLinks (TWA Play Store)', () => {
  it('package + sidik jari valid → satu statement handle_all_urls, huruf besar', () => {
    expect(assetLinks('id.clipper.app', 'ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab:ab, 01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01')).toEqual([
      {
        relation: ['delegate_permission/common.handle_all_urls'],
        target: { namespace: 'android_app', package_name: 'id.clipper.app', sha256_cert_fingerprints: ['AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB', '01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01:01'] },
      },
    ]);
  });
  it('kosong / package atau sidik jari rusak → null', () => {
    expect(assetLinks(undefined, undefined)).toBeNull();
    expect(assetLinks('clipper', 'AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB')).toBeNull();
    expect(assetLinks('id.clipper.app', 'AB:CD')).toBeNull();
  });
});
