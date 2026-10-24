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
  parsePages,
  trustEffects,
  matchShare,
  urlPlatform,
  appSiteAssociation,
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

describe('parsePages', () => {
  it('base64url JSON dari callback → id/nama terpotong, entri rusak dibuang', () => {
    const raw = btoa(JSON.stringify([{ id: 'p1', name: 'Halaman Satu' }, { name: 'tanpa id' }, { id: 'x'.repeat(80) }])).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    expect(parsePages(raw)).toEqual([{ id: 'p1', name: 'Halaman Satu' }, { id: 'x'.repeat(64), name: '' }]);
    expect(parsePages('%%%')).toEqual([]);
    expect(parsePages(undefined)).toEqual([]);
  });
});

describe('trustEffects', () => {
  it('instant dari ambang config; cap & hold hanya bila ada tier yang mengubahnya', () => {
    expect(trustEffects(80, { instantMin: 70, holdDays: 7, tiers: [] }).map((e) => [e.key, e.ok])).toEqual([['instant', true], ['premium', null]]);
    const tiers = [{ min_score: 0, cap_pct: 100, hold_days: 7 }, { min_score: 90, cap_pct: 150, hold_days: 3 }];
    expect(trustEffects(92, { instantMin: 70, holdDays: 7, tiers })).toEqual([
      { key: 'instant', ok: true, vars: { n: 70 } },
      { key: 'premium', ok: null, vars: {} },
      { key: 'cap', ok: true, vars: { n: 90, pct: 150 } },
      { key: 'hold', ok: true, vars: { n: 90, days: 3 } },
    ]);
    expect(trustEffects(50, { instantMin: null, holdDays: null, tiers }).filter((e) => e.ok === false).map((e) => e.key)).toEqual(['instant', 'cap', 'hold']);
  });
});

describe('urlPlatform & matchShare (share sheet → campaign)', () => {
  it('host video sosmed (termasuk link pendek) → platform; host lain → null', () => {
    expect(urlPlatform('https://vt.tiktok.com/ZS123/')).toBe('tiktok');
    expect(urlPlatform('https://www.tiktok.com/@raka.clips/video/7392')).toBe('tiktok');
    expect(urlPlatform('https://youtu.be/abc')).toBe('youtube');
    expect(urlPlatform('https://m.youtube.com/shorts/abc')).toBe('youtube');
    expect(urlPlatform('https://www.threads.net/@a/post/1')).toBe('threads');
    expect(urlPlatform('https://fb.watch/x')).toBe('facebook');
    expect(urlPlatform('https://twitter.com/a/status/1')).toBe('x');
    expect(urlPlatform('https://eviltiktok.com/x')).toBeNull();
    expect(urlPlatform('https://tiktok.com.evil.io/x')).toBeNull();
    expect(urlPlatform('nope')).toBeNull();
  });
  it('claim yang menerima platform link didahulukan, paling cepat habis dulu', () => {
    const a = { id: 'a', platforms: ['instagram'], expiresAt: '2026-10-21T05:00:00Z' };
    const b = { id: 'b', platforms: ['tiktok', 'instagram'], expiresAt: '2026-10-22T05:00:00Z' };
    const c = { id: 'c', platforms: ['tiktok'], expiresAt: '2026-10-21T09:00:00Z' };
    const r = matchShare('https://vt.tiktok.com/ZS1', [a, b, c]);
    expect(r.platform).toBe('tiktok');
    expect(r.best?.id).toBe('c');
    expect(r.matched.map((x) => x.id)).toEqual(['c', 'b']);
    expect(r.others.map((x) => x.id)).toEqual(['a']);
    expect(matchShare('https://example.com/v', [a, b]).best).toBeNull();
  });
});

describe('appSiteAssociation (universal link iOS)', () => {
  it('team + bundle valid → path native dibuka di app, API/OAuth/login dikecualikan lebih dulu', () => {
    const a = appSiteAssociation('ABCDE12345', 'id.clipper.app')!;
    const d = a.applinks.details[0]!;
    expect(d.appIDs).toEqual(['ABCDE12345.id.clipper.app']);
    expect(d.components.slice(0, 2)).toEqual([{ '/': '/api/*', exclude: true }, { '/': '/app-return*', exclude: true }]);
    expect(d.components).toContainEqual({ '/': '/campaigns/*' });
  });
  it('kosong / tidak valid → null (404)', () => {
    expect(appSiteAssociation(undefined, 'id.clipper.app')).toBeNull();
    expect(appSiteAssociation('abc', 'id.clipper.app')).toBeNull();
    expect(appSiteAssociation('ABCDE12345', 'bad id')).toBeNull();
  });
});
