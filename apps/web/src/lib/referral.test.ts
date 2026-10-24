import { describe, expect, it } from 'vitest';
import { refCode } from './referral';

describe('refCode', () => {
  it('accepts 8 lowercase alphanumerics', () => {
    expect(refCode('a1b2c3d4')).toBe('a1b2c3d4');
  });
  it('normalises case and whitespace', () => {
    expect(refCode(' A1B2C3D4 ')).toBe('a1b2c3d4');
  });
  it('rejects anything else', () => {
    for (const v of [null, undefined, '', 'a1b2c3d', 'a1b2c3d45', 'a1b2-3d4', 'a1b2c3d4;x', '<script>']) {
      expect(refCode(v)).toBeNull();
    }
  });
});
