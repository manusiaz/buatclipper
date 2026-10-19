// Bentuk JSON api.org_credit (kredit org D-09): saldo ledger org_credit, tersedia (dikurangi refund berjalan), riwayat, sisa per campaign.
type Obj = Record<string, unknown>;

const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const n = (v: unknown): number => {
  const x = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(x) ? x : 0;
};
const arr = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isObj) : []);
const str = (v: unknown): string => (typeof v === 'string' ? v : '');

export interface OrgCredit {
  balance: number;
  available: number;
  history: { amount: number; refType: string; refId: string; createdAt: string }[];
  leftovers: { campaignId: string; title: string; amount: number }[];
}

export function parseCredit(raw: unknown): OrgCredit {
  const c = isObj(raw) ? raw : {};
  return {
    balance: n(c.balance),
    available: n(c.available),
    history: arr(c.history).map((h) => ({ amount: n(h.amount), refType: str(h.ref_type), refId: str(h.ref_id), createdAt: str(h.created_at) })),
    leftovers: arr(c.leftovers).flatMap((l) =>
      str(l.campaign_id) && n(l.amount) > 0 ? [{ campaignId: str(l.campaign_id), title: str(l.title), amount: n(l.amount) }] : [],
    ),
  };
}

/** Bayar pakai kredit hanya untuk invoice terbit yang totalnya tertutup kredit tersedia (DB mengecek ulang). */
export const canPayWithCredit = (credit: Pick<OrgCredit, 'available'> | null, inv: { status: string; total: number }) =>
  !!credit && inv.status === 'issued' && inv.total > 0 && credit.available >= inv.total;
