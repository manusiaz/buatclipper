import { describe, expect, it } from 'vitest';
import { bankAmount, bankDate, parseBankCsv } from './bank';

describe('mutasi bank (G-11, A3.5)', () => {
  it('nominal format ID & EN, kurung & minus = debit', () => {
    expect(bankAmount('1.500.000,00')).toBe(1500000);
    expect(bankAmount('1,500,000.50')).toBe(1500000.5);
    expect(bankAmount('Rp 2.500')).toBe(2500);
    expect(bankAmount('(6.500)')).toBe(-6500);
    expect(bankAmount('-6500')).toBe(-6500);
    expect(bankAmount('12,5')).toBe(12.5);
    expect(bankAmount('abc')).toBeNull();
  });

  it('tanggal ISO / DD/MM/YYYY, tanggal mustahil ditolak', () => {
    expect(bankDate('2026-10-19')).toBe('2026-10-19');
    expect(bankDate('9/10/2026')).toBe('2026-10-09');
    expect(bankDate('31-02-2026')).toBeNull();
  });

  it('CSV titik koma dengan kolom debit/kredit; baris rusak dilaporkan, bukan dilewati', () => {
    const csv = '﻿Tanggal;Keterangan;Referensi;Debit;Kredit\n19/10/2026;"TRF; BRAND";INV-1;;1.500.000,00\n19/10/2026;Biaya;ADM;6.500;\nkemarin;x;R;1;\n';
    expect(parseBankCsv(csv)).toEqual({
      lines: [
        { date: '2026-10-19', amount: 1500000, reference: 'INV-1', description: 'TRF; BRAND' },
        { date: '2026-10-19', amount: -6500, reference: 'ADM', description: 'Biaya' },
      ],
      badRows: [4],
    });
  });

  it('kolom wajib tidak ada → baris judul ditandai', () => {
    expect(parseBankCsv('date,amount\n2026-10-19,100')).toEqual({ lines: [], badRows: [1] });
    expect(parseBankCsv('date,amount,reference\n2026-10-19,-100,PO-1').lines).toEqual([
      { date: '2026-10-19', amount: -100, reference: 'PO-1', description: '' },
    ]);
  });
});
