import type { CoreClient } from '@clipper/db-core';

/** Budget & terpakai per campaign dalam Rupiah (Σ unit pool × nilai Rp per unit reward type). */
export async function poolBudgets(core: CoreClient, campaignIds: string[]): Promise<Map<string, { budget: number; used: number }>> {
  const out = new Map<string, { budget: number; used: number }>();
  if (!campaignIds.length) return out;
  const { data: pools } = await core.from('reward_pools').select('campaign_id, reward_type_id, total, allocated').in('campaign_id', campaignIds);
  const typeIds = [...new Set((pools ?? []).map((p) => p.reward_type_id).filter((x): x is string => !!x))];
  const { data: types } = typeIds.length
    ? await core.from('reward_types').select('id, idr_value_per_unit').in('id', typeIds)
    : { data: [] as { id: string | null; idr_value_per_unit: number | null }[] };
  const idr = new Map((types ?? []).map((r) => [r.id, Number(r.idr_value_per_unit ?? 0)]));
  for (const p of pools ?? []) {
    if (!p.campaign_id) continue;
    const v = idr.get(p.reward_type_id) ?? 0;
    const cur = out.get(p.campaign_id) ?? { budget: 0, used: 0 };
    cur.budget += Number(p.total ?? 0) * v;
    cur.used += Number(p.allocated ?? 0) * v;
    out.set(p.campaign_id, cur);
  }
  return out;
}
