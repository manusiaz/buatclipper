import { unstable_cache } from 'next/cache';
import { hosts } from '@clipper/auth';
import { core, deadline } from './core';
import { ADMIN_FEE_PCT, MGMT_FEE_PCT } from '../features/landing/fees';
import { publicSettings, type PublicSettings } from './settings';

export interface Category {
  id: string;
  name_id: string;
  name_en: string;
}

export const getCategories = unstable_cache(
  async (): Promise<Category[]> => {
    const { data, error } = await core.from('categories').select('id, name_id, name_en').order('sort').abortSignal(deadline());
    if (error) throw new Error(error.message);
    return (data ?? []).filter((c): c is Category => !!c.id && !!c.name_id && !!c.name_en);
  },
  ['web:categories'],
  { revalidate: 3600 },
);

export async function categoryName(id: string | null | undefined, locale: string): Promise<string | undefined> {
  if (!id) return undefined;
  const list = await getCategories().catch(() => [] as Category[]);
  const c = list.find((x) => x.id === id);
  return c ? (locale === 'en' ? c.name_en : c.name_id) : undefined;
}

const KEYS = [
  'public.finance.min_withdraw_idr',
  'public.billing.managed_service_idr',
  'public.market.max_accounts_per_platform',
  'public.market.claim_hours',
  'public.finance.hold_days',
  'public.flags.platforms',
  'public.home.banners',
];

/** Config publik (ops.settings public.*, terbaca anon). Gagal → default PRD. */
export const getPublicSettings = unstable_cache(
  async (): Promise<PublicSettings> => {
    const { data, error } = await core.from('settings').select('key, value').in('key', KEYS).abortSignal(deadline(2500));
    if (error) throw new Error(error.message);
    return publicSettings(data ?? [], hosts.app);
  },
  ['web:settings'],
  { revalidate: 300 },
);

export const settingsOrDefault = () => getPublicSettings().catch(() => publicSettings([]));

/** Fee rule global (E-21, terbaca anon) untuk kalkulator biaya B1.1. Gagal → default PRD. */
export const getGlobalFee = unstable_cache(
  async () => {
    const { data, error } = await core.from('fee_rules').select('mgmt_fee_pct, admin_fee_pct').eq('scope', 'global').abortSignal(deadline(2500)).maybeSingle();
    if (error) throw new Error(error.message);
    return { mgmt: Number(data?.mgmt_fee_pct ?? MGMT_FEE_PCT), admin: Number(data?.admin_fee_pct ?? ADMIN_FEE_PCT) };
  },
  ['web:fee'],
  { revalidate: 300 },
);

export const globalFeeOrDefault = () => getGlobalFee().catch(() => ({ mgmt: MGMT_FEE_PCT, admin: ADMIN_FEE_PCT }));
