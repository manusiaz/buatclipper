import { describe, expect, it } from 'vitest';
import { checkNik, cleanNik, todayJakarta } from './nik';

const today = { y: 2026, m: 10, d: 19 };

describe('checkNik', () => {
  it('reads the birth date of an adult', () => {
    expect(checkNik('3174011205980001', today)).toEqual({ ok: true, birth: { y: 1998, m: 5, d: 12 }, age: 28 });
  });
  it('subtracts 40 from the day for women', () => {
    expect(checkNik('3174015205980001', today)).toMatchObject({ ok: true, birth: { y: 1998, m: 5, d: 12 } });
  });
  it('rejects under 18 (birthday tomorrow)', () => {
    expect(checkNik('3174012010080001', today)).toMatchObject({ ok: false, error: 'under_age', age: 17 });
    expect(checkNik('3174011910080001', today)).toMatchObject({ ok: true, age: 18 });
  });
  it('resolves the century so the date is not in the future', () => {
    expect(checkNik('3174010101300001', today)).toMatchObject({ ok: true, birth: { y: 1930 } });
  });
  it('rejects malformed NIK', () => {
    for (const nik of ['123', '0000001205980001', '3174011205980000', '3174013213980001', '3174013002000001']) {
      expect(checkNik(nik, today)).toEqual({ ok: false, error: 'invalid_nik' });
    }
  });
  it('accepts 29 Feb only in leap years', () => {
    expect(checkNik('3174012902000001', today)).toMatchObject({ ok: true, birth: { y: 2000, m: 2, d: 29 } });
    expect(checkNik('3174012902010001', today)).toEqual({ ok: false, error: 'invalid_nik' });
  });
});

describe('helpers', () => {
  it('cleanNik keeps 16 digits', () => expect(cleanNik('3174 0112-0598.0001 99')).toBe('3174011205980001'));
  it('todayJakarta is UTC+7', () => expect(todayJakarta(new Date('2026-10-18T17:30:00Z'))).toEqual({ y: 2026, m: 10, d: 19 }));
});
