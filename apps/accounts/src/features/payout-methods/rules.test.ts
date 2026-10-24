import { describe, expect, it } from 'vitest';
import { bankName, normalizeAccountNo, piiFields, sameName } from './rules';

describe('normalizeAccountNo', () => {
  it('bank: 5–20 digits, separators removed', () => {
    expect(normalizeAccountNo('bank', '123-456 7890')).toBe('1234567890');
    expect(normalizeAccountNo('bank', '1234')).toBeNull();
    expect(normalizeAccountNo('bank', '12a45')).toBeNull();
  });
  it('ewallet: Indonesian mobile number, 62/+62 → 0', () => {
    expect(normalizeAccountNo('ewallet', '+62 812-3456-7890')).toBe('081234567890');
    expect(normalizeAccountNo('ewallet', '0812345678')).toBe('0812345678');
    expect(normalizeAccountNo('ewallet', '021555666')).toBeNull();
  });
});

describe('names', () => {
  it('sameName ignores case and extra spaces', () => expect(sameName(' Rani  Putri ', 'rani putri')).toBe(true));
  it('bankName falls back to the code', () => {
    expect(bankName('BCA')).toBe('BCA');
    expect(bankName('XYZ')).toBe('XYZ');
  });
});

describe('piiFields', () => {
  it('keeps only valid PII fields with required default true', () => {
    const schema = [
      { key: 'game_user_id', pii: false, required: true },
      { key: 'address', pii: true },
      { key: 'phone', pii: 'true', required: false, label: 'No. HP' },
      { key: 'Bad Key', pii: true },
      null,
    ];
    expect(piiFields(schema)).toEqual([
      { key: 'address', label: undefined, required: true },
      { key: 'phone', label: 'No. HP', required: false },
    ]);
  });
  it('non-array → empty', () => expect(piiFields({})).toEqual([]));
});
