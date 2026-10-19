import { describe, expect, it } from 'vitest';
import { parseCodes } from './codes';

describe('parseCodes', () => {
  it('splits lines/commas, trims, dedupes', () => {
    expect(parseCodes(' A1 \nB2,B2;"C3"\r\n\n\tD4 ')).toEqual(['A1', 'B2', 'C3', 'D4']);
    expect(parseCodes('\n , ')).toEqual([]);
  });
});
