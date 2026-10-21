import { describe, expect, it } from 'vitest';
import { earningsBySubmission, formatAmount } from './units';

const idr = { id: 'u-idr', code: 'IDR', unit_label: 'Rp', decimals: 0 };
const pts = { id: 'u-pts', code: 'PTS', unit_label: 'Poin', decimals: 0 };

describe('earningsBySubmission', () => {
  it('Rp dan poin dari pool berbeda tidak dijumlah; pending/released per unit', () => {
    const of = earningsBySubmission(
      [
        { submission_id: 's1', pool_id: 'p-idr', amount: 10000, released_at: null },
        { submission_id: 's1', pool_id: 'p-idr', amount: '2500', released_at: '2026-10-01T00:00:00Z' },
        { submission_id: 's1', pool_id: 'p-pts', amount: 50, released_at: null },
        { submission_id: 's2', pool_id: 'p-idr', amount: 0, released_at: null },
      ],
      new Map([['p-idr', idr], ['p-pts', pts]]),
    );
    expect(of('s1')).toEqual([
      { unit: idr, pending: 10000, released: 2500 },
      { unit: pts, pending: 50, released: 0 },
    ]);
    expect(of('s1').map((e) => formatAmount(e.pending + e.released, e.unit, 'id'))).toEqual(['Rp12.500', '50 Poin']);
    expect(of('s2')).toEqual([]);
    expect(of('nope')).toEqual([]);
  });
});
