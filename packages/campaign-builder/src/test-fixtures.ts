import { newDraft } from './model';
import type { BuilderContext, CampaignDraft } from './types';

export const ORG = '44444444-0000-0000-0000-000000000001';
export const CAMPAIGN = '55555555-0000-0000-0000-0000000000c1';
export const RT_IDR = '77777777-0000-0000-0000-000000000001';
export const RT_DM = '77777777-0000-0000-0000-0000000000d1';

export const ctx: BuilderContext = {
  mode: 'brand',
  org: { id: ORG, name: 'Studio Satu', status: 'verified' },
  categories: [{ id: 'games', name_id: 'Game', name_en: 'Games' }],
  rewardTypes: [
    { id: RT_IDR, code: 'IDR', name: 'Rupiah', unit_label: 'Rp', kind: 'cash', idr_value_per_unit: 1, decimals: 0, owner_org_id: null },
    { id: RT_DM, code: 'MLBB_DIAMOND', name: 'Diamonds', unit_label: 'Diamonds', kind: 'in_game', idr_value_per_unit: 250, decimals: 0, owner_org_id: ORG },
  ],
  platforms: { tiktok: true, instagram: true, youtube: true, threads: false, facebook: false, x: false },
  fee: { mgmt_fee_pct: 15, admin_fee_pct: 5 },
  taxPct: 11,
  managedServiceIdr: 2_500_000,
};

/** A complete, submittable draft (PRD §5.2 numbers: Rp10.000.000 at Rp2.000 / 1.000 views). */
export function validDraft(overrides: Partial<CampaignDraft> = {}): CampaignDraft {
  const d = newDraft(ctx);
  const pool = { ...d.pools[0]!, key: 'idr', total: 10_000_000, max_per_clip: 1_000_000 };
  return {
    ...d,
    title: 'Film Baru Rilis',
    category_id: 'games',
    platforms: ['tiktok', 'instagram'],
    brief: 'Potong adegan terbaik.',
    pools: [pool],
    rules: [{ key: 'r1', kind: 'per_1k_views', pool: 'idr', platform: null, params: { rate: 2000 } }],
    start_at: '2099-01-01T03:00:00.000Z',
    submit_deadline: '2099-01-15T03:00:00.000Z',
    ...overrides,
  };
}
