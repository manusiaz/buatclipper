import type { CoreClient } from '@clipper/db-core';

/** Campaign org dengan review_mode brand (F-B07). */
export async function brandReviewCampaigns(core: CoreClient, orgId: string) {
  const { data } = await core.from('campaigns').select('id, title').eq('org_id', orgId).eq('review_mode', 'brand').eq('is_template', false);
  return (data ?? []).flatMap((c) => (c.id ? [{ id: c.id, title: c.title ?? '' }] : []));
}

export async function pendingReviewCount(core: CoreClient, orgId: string): Promise<number> {
  const ids = (await brandReviewCampaigns(core, orgId)).map((c) => c.id);
  if (!ids.length) return 0;
  const { count } = await core.from('submissions').select('id', { count: 'exact', head: true }).in('campaign_id', ids).eq('status', 'in_review');
  return count ?? 0;
}
