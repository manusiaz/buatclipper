// Filter daftar campaign (F-C03) ↔ query string ↔ p_filters api.list_campaigns.
import { isPlatform } from './pure';

export const SORTS = ['newest', 'rate', 'budget', 'deadline'] as const;
export const STATUSES = ['active', 'live', 'paused', 'ended', 'all'] as const;
export type Sort = (typeof SORTS)[number];
export type StatusFilter = (typeof STATUSES)[number];

export interface CampaignFilters {
  q: string;
  platform: string;
  category: string;
  status: StatusFilter;
  sort: Sort;
}

type Params = Record<string, string | string[] | undefined>;
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? '';

export function parseFilters(sp: Params): CampaignFilters {
  const status = one(sp.status) as StatusFilter;
  const sort = one(sp.sort) as Sort;
  const platform = one(sp.platform);
  return {
    q: one(sp.q).trim().slice(0, 80),
    platform: isPlatform(platform) ? platform : '',
    category: /^[a-z0-9_-]{1,40}$/.test(one(sp.category)) ? one(sp.category) : '',
    status: STATUSES.includes(status) ? status : 'active',
    sort: SORTS.includes(sort) ? sort : 'newest',
  };
}

export function filtersToQuery(f: CampaignFilters): string {
  const p = new URLSearchParams();
  if (f.q) p.set('q', f.q);
  if (f.platform) p.set('platform', f.platform);
  if (f.category) p.set('category', f.category);
  if (f.status !== 'active') p.set('status', f.status);
  if (f.sort !== 'newest') p.set('sort', f.sort);
  const s = p.toString();
  return s ? `?${s}` : '';
}

/** p_filters: status default live+paused (kosong), "ended" = campaign yang sudah tidak menerima claim. */
export function toRpcFilters(f: CampaignFilters, limit = 12): Record<string, unknown> {
  const out: Record<string, unknown> = { sort: f.sort, limit };
  if (f.q) out.q = f.q;
  if (f.platform) out.platform = f.platform;
  if (f.category) out.category = f.category;
  if (f.status === 'ended') out.status = ['tracking', 'exhausted', 'settling', 'settled'];
  else if (f.status !== 'active') out.status = f.status;
  return out;
}

export const isFiltered = (f: CampaignFilters) => !!(f.q || f.platform || f.category || f.status !== 'active');
