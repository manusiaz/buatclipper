import { describe, expect, it } from 'vitest';
import { batchIsToday, buildWidgetSnapshot, type WidgetInput } from './widget-snapshot';

const base: WidgetInput = { signedIn: true, available: 482000, pending: 126000, payout: null, review: 2, campaigns: [] };
const tue = new Date('2026-10-20T02:00:00Z'); // Selasa 09.00 WIB
const monEarly = new Date('2026-10-26T01:00:00Z'); // Senin 08.00 WIB

describe('buildWidgetSnapshot (widget Android & iOS)', () => {
  it('saldo, ditahan, review, tanpa penarikan → siap ditarik', () => {
    const s = buildWidgetSnapshot(base, 'id', tue);
    expect(s.balance).toBe('Rp482.000');
    expect(s.held).toBe('+Rp126.000 ditahan');
    expect(s.release).toBe('Siap ditarik');
    expect(s.reviewLine).toBe('2 clip nunggu approve');
  });
  it('penarikan batch: Senin pagi = cair hari ini + rekening tersamar; hari lain = cair Senin', () => {
    const payout = { status: 'requested', channel: 'batch', bank_code: 'bca', account_last4: '4821' };
    expect(buildWidgetSnapshot({ ...base, payout }, 'id', monEarly).release).toBe('Cair hari ini · BCA •• 4821');
    expect(buildWidgetSnapshot({ ...base, payout }, 'id', tue).release).toBe('Cair Senin · BCA •• 4821');
    expect(buildWidgetSnapshot({ ...base, payout: { ...payout, status: 'processing' } }, 'en', tue).release).toBe('Transferring · BCA •• 4821');
    expect(batchIsToday(new Date('2026-10-26T03:30:00Z'))).toBe(false);
  });
  it('campaign baru: jumlah, rate tertinggi, daftar yang bisa diambil saja', () => {
    const s = buildWidgetSnapshot(
      {
        ...base,
        campaigns: [
          { id: 'a', title: 'Arena Nusantara Cup', category: 'Game', isNew: true, ctaState: 'can_claim', rates: [{ ratePer1k: 2000 }], budgetUsedRatio: 0.36 },
          { id: 'b', title: 'Kuasa Gelap 2', isNew: true, ctaState: 'slots_full', rates: [{ ratePer1k: 3000 }] },
          { id: 'c', title: 'Lama', isNew: false, ctaState: 'can_claim', rates: [{ ratePer1k: 9000 }] },
        ],
      },
      'id',
      tue,
    );
    expect(s.newCount).toBe('2');
    expect(s.topRate).toBe('Rp3.000');
    expect(s.campaigns).toEqual([{ title: 'Arena Nusantara Cup', sub: 'Game · sisa 64%', rate: 'Rp2.000/1K', url: 'clipper://campaign/a' }]);
  });
  it('belum login → tanpa angka', () => {
    const s = buildWidgetSnapshot({ ...base, signedIn: false }, 'id', tue);
    expect([s.balance, s.release, s.held]).toEqual(['—', '', '']);
  });
});
