'use server';

import { requireClipper } from '@clipper/auth/server';
import { fetchCampaignPage, type CampaignCardData } from './cards';
import { parseFilters, type CampaignFilters } from '@clipper/clipper-lib/filters';

/** Infinite scroll F-C03: halaman berikut dari next_cursor baris terakhir. */
export async function loadMoreCampaigns(
  filters: CampaignFilters,
  cursor: string,
): Promise<{ ok: true; items: CampaignCardData[]; next: string | null } | { ok: false; message: string }> {
  await requireClipper();
  const f = parseFilters({ ...filters });
  return fetchCampaignPage(f, typeof cursor === 'string' && cursor.length < 200 ? cursor : null);
}
