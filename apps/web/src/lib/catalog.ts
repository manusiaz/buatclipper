import { unstable_cache } from 'next/cache';
import { core, deadline } from './core';
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
  'public.flags.platforms',
];

/** Config publik (ops.settings public.*, terbaca anon). Gagal → default PRD. */
export const getPublicSettings = unstable_cache(
  async (): Promise<PublicSettings> => {
    const { data, error } = await core.from('settings').select('key, value').in('key', KEYS).abortSignal(deadline(2500));
    if (error) throw new Error(error.message);
    return publicSettings(data ?? []);
  },
  ['web:settings'],
  { revalidate: 300 },
);

export const settingsOrDefault = () => getPublicSettings().catch(() => publicSettings([]));
