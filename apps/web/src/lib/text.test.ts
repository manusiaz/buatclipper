import { describe, expect, it } from 'vitest';
import { plainExcerpt } from './text';

describe('plainExcerpt', () => {
  it('strips common markdown and html', () => {
    expect(plainExcerpt('# Judul\n\n**Potong** momen [terbaik](https://x.co) dari _film_.\n- satu\n- dua <b>x</b>')).toBe(
      'Judul Potong momen terbaik dari film. satu dua x',
    );
  });
  it('cuts on a word boundary with an ellipsis', () => {
    const out = plainExcerpt('kata '.repeat(60), 40);
    expect(out.length).toBeLessThanOrEqual(40);
    expect(out.endsWith('kata…')).toBe(true);
  });
  it('handles empty input', () => {
    expect(plainExcerpt(null)).toBe('');
    expect(plainExcerpt('   ')).toBe('');
  });
});
