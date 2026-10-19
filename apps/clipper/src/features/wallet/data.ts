// Saldo per reward type × bucket S-04 (api.wallet_balances) — dipakai Wallet & Withdraw.
import { num } from '../lib/pure';
import { core, rewardTypes, type RewardUnit } from '../lib/server';

export interface Balance {
  unit: RewardUnit;
  pending: number;
  available: number;
  withdrawn: number;
}

export async function idrRewardType(): Promise<RewardUnit | null> {
  const db = await core();
  const { data } = await db.from('reward_types').select('id').eq('code', 'IDR').is('owner_org_id', null).maybeSingle();
  return data?.id ? ((await rewardTypes([data.id])).get(data.id) ?? null) : null;
}

export async function balances(uid: string): Promise<{ idr: Balance | null; others: Balance[] }> {
  const db = await core();
  const [{ data }, idrType] = await Promise.all([
    db.from('wallet_balances').select('reward_type_id,state,amount').eq('user_id', uid),
    idrRewardType(),
  ]);
  const rows = data ?? [];
  const units = await rewardTypes([...rows.map((r) => r.reward_type_id!), ...(idrType ? [idrType.id] : [])]);
  const map = new Map<string, Balance>();
  for (const u of units.values()) map.set(u.id, { unit: u, pending: 0, available: 0, withdrawn: 0 });
  for (const r of rows) {
    const b = map.get(r.reward_type_id ?? '');
    if (b && (r.state === 'pending' || r.state === 'available' || r.state === 'withdrawn')) b[r.state] += num(r.amount);
  }
  const idr = idrType ? map.get(idrType.id) ?? null : null;
  const others = [...map.values()].filter((b) => b.unit.id !== idrType?.id && (b.pending || b.available || b.withdrawn));
  return { idr, others };
}
