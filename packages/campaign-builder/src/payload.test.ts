import { describe, expect, it } from 'vitest';
import { toSavePayload } from './payload';
import { CAMPAIGN, ORG, RT_DM, RT_IDR, validDraft } from './test-fixtures';

/** Keys api.save_campaign accepts in p_campaign (anything else raises invalid:unknown_key). */
const ACCEPTED = new Set([
  'title', 'slug', 'type', 'category_id', 'platforms', 'brief', 'required_hashtags', 'required_mentions', 'required_links',
  'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls', 'faq', 'service_mode', 'start_at',
  'submit_deadline', 'view_window_days', 'review_mode', 'min_followers', 'min_account_age_days', 'min_trust_score', 'kyc_required',
  'min_views', 'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility', 'is_template',
  'id', 'org_id', 'pools', 'rules', 'assets', 'fee_rule',
]);

describe('toSavePayload', () => {
  it('produces exactly the p_campaign shape of api.save_campaign for a new campaign', () => {
    const p = toSavePayload(
      validDraft({
        required_hashtags: ['#MPLID', ' Clipper ', '#mplid'],
        required_mentions: ['@StudioSatu'],
        required_links: ['studio.id/promo'],
        dos: [' Pakai subtitle ', ''],
        faq: [{ q: ' Boleh musik? ', a: 'Bebas lisensi' }, { q: '', a: '' }],
      }),
    );
    for (const k of Object.keys(p)) expect(ACCEPTED.has(k), k).toBe(true);
    expect(p).not.toHaveProperty('id');
    expect(p).not.toHaveProperty('slug');
    expect(p).not.toHaveProperty('fee_rule');
    expect(p).toMatchObject({
      org_id: ORG,
      title: 'Film Baru Rilis',
      type: 'clipping',
      category_id: 'games',
      platforms: ['tiktok', 'instagram'],
      required_hashtags: ['mplid', 'clipper'],
      required_mentions: ['studiosatu'],
      required_links: ['https://studio.id/promo'],
      dos: ['Pakai subtitle'],
      faq: [{ q: 'Boleh musik?', a: 'Bebas lisensi' }],
      sponsored_label: true,
      min_views: 1000,
      max_clips_per_clipper: 10,
      clipper_quota: null,
      view_window_days: 30,
      review_mode: 'manual',
      visibility: 'public',
      service_mode: 'self_serve',
      start_at: '2099-01-01T03:00:00.000Z',
      submit_deadline: '2099-01-15T03:00:00.000Z',
      pools: [{ key: 'idr', reward_type_id: RT_IDR, total: 10_000_000, max_per_clip: 1_000_000 }],
      rules: [{ kind: 'per_1k_views', pool: 'idr', params: { rate: 2000 } }],
      assets: [],
    });
  });

  it('existing campaign: id instead of org_id; pool ids kept; rule platform and per-kind params only', () => {
    const p = toSavePayload(
      validDraft({
        id: CAMPAIGN,
        slug: ' Film-Satu ',
        pools: [
          { key: 'pool-a', id: 'pool-a', reward_type_id: RT_IDR, total: 5_000_000, max_per_clip: 500_000 },
          { key: 'dm', id: null, reward_type_id: RT_DM, total: 50_000, max_per_clip: 2000 },
        ],
        rules: [
          { key: 'r1', kind: 'per_1k_views', pool: 'pool-a', platform: 'tiktok', params: { rate: 2000, amount: 99 } },
          { key: 'r2', kind: 'milestone_bonus', pool: 'pool-a', platform: null, params: { threshold: 100_000, amount: 50_000 } },
          {
            key: 'r3',
            kind: 'tiered_cpm',
            pool: 'dm',
            platform: 'instagram',
            params: { tiers: [{ from: 0, to: 50_000, rate: 8 }, { from: 50_000, to: null, rate: 6 }] },
          },
          { key: 'r4', kind: 'flat_per_post', pool: 'dm', platform: null, params: { amount: 100 } },
        ],
      }),
    );
    expect(p.id).toBe(CAMPAIGN);
    expect(p).not.toHaveProperty('org_id');
    expect(p.slug).toBe('film-satu');
    expect(p.pools).toEqual([
      { id: 'pool-a', key: 'pool-a', reward_type_id: RT_IDR, total: 5_000_000, max_per_clip: 500_000 },
      { key: 'dm', reward_type_id: RT_DM, total: 50_000, max_per_clip: 2000 },
    ]);
    expect(p.rules).toEqual([
      { kind: 'per_1k_views', pool: 'pool-a', platform: 'tiktok', params: { rate: 2000 } },
      { kind: 'milestone_bonus', pool: 'pool-a', params: { threshold: 100_000, amount: 50_000 } },
      { kind: 'tiered_cpm', pool: 'dm', platform: 'instagram', params: { tiers: [{ from: 0, to: 50_000, rate: 8 }, { from: 50_000, rate: 6 }] } },
      { kind: 'flat_per_post', pool: 'dm', params: { amount: 100 } },
    ]);
  });

  it('holds back pools + rules while any of them is incomplete (server would reject the whole save)', () => {
    const p = toSavePayload(validDraft({ pools: [{ key: 'idr', id: null, reward_type_id: RT_IDR, total: null, max_per_clip: 1000 }] }));
    expect(p).not.toHaveProperty('pools');
    expect(p).not.toHaveProperty('rules');
    expect(p.title).toBe('Film Baru Rilis');
    const q = toSavePayload(validDraft({ rules: [{ key: 'r', kind: 'per_1k_views', pool: 'idr', platform: null, params: { rate: 0 } }] }));
    expect(q).not.toHaveProperty('pools');
  });

  it('empty pool list is sent (deletes pools in a draft)', () => {
    const p = toSavePayload(validDraft({ pools: [], rules: [] }));
    expect(p.pools).toEqual([]);
    expect(p.rules).toEqual([]);
  });

  it('assets: complete list = cover + clipper assets/links + internal files', () => {
    const base = `${ORG}/${CAMPAIGN}/`;
    const p = toSavePayload(
      validDraft({
        id: CAMPAIGN,
        cover: { key: 'c', id: 'a1', kind: 'cover', audience: 'clipper', storage_path: `${base}cover.webp`, url: null, size_bytes: 1200, name: 'cover.webp' },
        assets: [
          { key: 'v', id: null, kind: 'video', audience: 'clipper', storage_path: `${base}raw.mp4`, url: null, size_bytes: 9_000_000, name: 'raw.mp4' },
          { key: 'l', id: null, kind: 'link', audience: 'clipper', storage_path: null, url: 'https://drive.example/folder', size_bytes: null, name: 'drive.example' },
        ],
        internal_files: [{ key: 'i', id: null, kind: 'document', audience: 'internal', storage_path: `${base}internal/brief.pdf`, url: null, size_bytes: null, name: 'brief.pdf' }],
      }),
    );
    expect(p.assets).toEqual([
      { kind: 'cover', storage_path: `${base}cover.webp`, audience: 'clipper', size_bytes: 1200 },
      { kind: 'video', storage_path: `${base}raw.mp4`, audience: 'clipper', size_bytes: 9_000_000 },
      { kind: 'link', url: 'https://drive.example/folder', audience: 'clipper' },
      { kind: 'document', storage_path: `${base}internal/brief.pdf`, audience: 'internal' },
    ]);
  });

  it('fee override: keep → omitted, clear → null, set → {mgmt_fee_pct, admin_fee_pct}', () => {
    expect(toSavePayload(validDraft({ fee: { mode: 'keep' } }))).not.toHaveProperty('fee_rule');
    expect(toSavePayload(validDraft({ fee: { mode: 'clear' } })).fee_rule).toBeNull();
    expect(toSavePayload(validDraft({ fee: { mode: 'set', source_id: 'x', mgmt_fee_pct: 10, admin_fee_pct: 5 } })).fee_rule).toEqual({
      mgmt_fee_pct: 10,
      admin_fee_pct: 5,
    });
  });

  it('submitted campaign (brief frozen): only {id, faq}', () => {
    for (const status of ['in_review', 'scheduled', 'live', 'paused'] as const) {
      const p = toSavePayload(validDraft({ id: CAMPAIGN, status, faq: [{ q: 'Durasi?', a: '15-60 detik' }, { q: ' ', a: '' }] }));
      expect(p).toEqual({ id: CAMPAIGN, faq: [{ q: 'Durasi?', a: '15-60 detik' }] });
    }
  });

  it('rejected campaign is still fully editable (save_campaign moves it back to draft)', () => {
    const p = toSavePayload(validDraft({ id: CAMPAIGN, status: 'rejected' }));
    expect(p).toHaveProperty('title');
    expect(p).toHaveProperty('pools');
  });
});

describe('toSavePayload managed', () => {
  it('kirim brief mentah brand ke managed_brief, brief final tidak tertimpa', () => {
    const p = toSavePayload({ ...validDraft(), service_mode: 'managed', brief: '', managed_brief: 'Buatkan dari trailer.' });
    expect(p.managed_brief).toBe('Buatkan dari trailer.');
    expect(p.brief).toBe('');
  });
  it('self-serve tanpa brief mentah tidak mengirim managed_brief', () => {
    expect('managed_brief' in toSavePayload({ ...validDraft(), service_mode: 'self_serve', managed_brief: '' })).toBe(false);
  });
});
