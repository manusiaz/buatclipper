import { describe, expect, it } from 'vitest';
import { canPayWithCredit, parseCredit } from './credit';

describe('parseCredit', () => {
  it('tolerates empty input', () => {
    expect(parseCredit(null)).toEqual({ balance: 0, available: 0, history: [], leftovers: [] });
  });
  it('reads numbers and drops empty leftovers', () => {
    const c = parseCredit({
      balance: '2000000',
      available: 1500000.5,
      history: [{ amount: -500000, ref_type: 'invoice_payment', ref_id: 'x', created_at: '2026-10-19T10:00:00Z' }],
      leftovers: [{ campaign_id: 'c1', title: 'A', amount: 2000000 }, { campaign_id: 'c2', title: 'B', amount: 0 }, { title: 'C', amount: 5 }],
    });
    expect(c.balance).toBe(2_000_000);
    expect(c.available).toBe(1_500_000.5);
    expect(c.history[0]).toEqual({ amount: -500000, refType: 'invoice_payment', refId: 'x', createdAt: '2026-10-19T10:00:00Z' });
    expect(c.leftovers).toEqual([{ campaignId: 'c1', title: 'A', amount: 2_000_000 }]);
  });
});

describe('canPayWithCredit', () => {
  it('needs an issued invoice fully covered by available credit', () => {
    expect(canPayWithCredit({ available: 555000 }, { status: 'issued', total: 555000 })).toBe(true);
    expect(canPayWithCredit({ available: 554999 }, { status: 'issued', total: 555000 })).toBe(false);
    expect(canPayWithCredit({ available: 1e9 }, { status: 'paid', total: 555000 })).toBe(false);
    expect(canPayWithCredit(null, { status: 'issued', total: 1 })).toBe(false);
  });
});
