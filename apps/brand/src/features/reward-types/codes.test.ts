import { describe, expect, it } from 'vitest';
import { parseCodes } from './codes';

describe('parseCodes', () => {
  it('splits lines, spaces and commas, trims and dedupes', () => {
    expect(parseCodes(' A1 \nB2, C3\n\nA1\r\nD4 E5;F6')).toEqual(['A1', 'B2', 'C3', 'D4', 'E5', 'F6']);
  });
  it('takes the first CSV column and skips the header', () => {
    expect(parseCodes('code,expiry\n"X-1",2026-12-31\nY-2;foo\n', true)).toEqual(['X-1', 'Y-2']);
  });
});
