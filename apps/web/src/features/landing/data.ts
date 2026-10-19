import { unstable_cache } from 'next/cache';
import type { CoreFn } from '@clipper/db-core';
import { core, deadline } from '@/lib/core';

export type LiveCampaign = CoreFn<'list_campaigns'>['Returns'][number];

/** C1.1: campaign live terbaru untuk anon (cta NULL). Pinned dulu, lalu terbaru — urutan dari api.list_campaigns. */
export const getLiveCampaigns = unstable_cache(
  async (): Promise<LiveCampaign[]> => {
    const { data, error } = await core.rpc('list_campaigns', { p_filters: { status: 'live', sort: 'newest', limit: 6 } }).abortSignal(deadline());
    if (error) throw new Error(error.message);
    return data ?? [];
  },
  ['web:live-campaigns'],
  { revalidate: 60 },
);
