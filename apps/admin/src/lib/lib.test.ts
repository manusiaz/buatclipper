import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { dbError } from './errors';
import { isoToWibDate, isoToWibInput, wibToIso } from './wib';
import { likeTerm } from './data';

describe('dbError', () => {
  it('keeps machine codes from api functions', () => {
    expect(dbError({ message: 'invoice_unpaid', code: 'P0001' })).toBe('invoice_unpaid');
    expect(dbError({ message: 'invalid_state:draft', code: 'P0001' })).toBe('invalid_state:draft');
    expect(dbError({ message: 'not_found:campaign', code: 'P0002' })).toBe('not_found:campaign');
  });
  it('maps free-text and constraint errors by SQLSTATE', () => {
    expect(dbError({ message: 'butuh admin_moderator + aal2', code: '42501' })).toBe('auth:forbidden');
    expect(dbError({ message: 'tidak ada KYC menunggu', code: 'P0002' })).toBe('not_found');
    expect(dbError({ message: 'new row violates check constraint "payout_batches_two_person"', code: '23514' })).toBe('two_person');
    expect(dbError({ message: 'TypeError: fetch failed', code: '' })).toBe('network');
    expect(dbError({ message: 'something odd', code: 'XX000' })).toBe('generic');
    expect(dbError(null)).toBe('generic');
  });
});

describe('WIB inputs', () => {
  it('reads datetime-local as UTC+7', () => {
    expect(wibToIso('2026-10-19T07:00')).toBe('2026-10-19T00:00:00.000Z');
    expect(wibToIso('')).toBeNull();
    expect(wibToIso('19/10/2026')).toBeNull();
  });
  it('round-trips', () => {
    expect(isoToWibInput('2026-10-19T00:00:00.000Z')).toBe('2026-10-19T07:00');
    expect(isoToWibInput(wibToIso('2026-12-31T23:59'))).toBe('2026-12-31T23:59');
    expect(isoToWibInput(null)).toBe('');
    expect(isoToWibDate('2026-10-19T18:00:00Z')).toBe('2026-10-20');
  });
});

describe('likeTerm', () => {
  it('strips PostgREST filter syntax', () => {
    expect(likeTerm('ab,c(d)%')).toBe('%ab c d%');
  });
});

describe('admin messages', () => {
  const flat = (o: Record<string, unknown>, p = ''): string[] =>
    Object.entries(o).flatMap(([k, v]) => (v && typeof v === 'object' ? flat(v as Record<string, unknown>, `${p}${k}.`) : [`${p}${k}`]));
  const load = (l: string) => JSON.parse(readFileSync(new URL(`../../../../packages/i18n/messages/${l}/admin.json`, import.meta.url), 'utf8'));
  it('ID and EN have identical keys', () => {
    expect(flat(load('en')).sort()).toEqual(flat(load('id')).sort());
  });
});
