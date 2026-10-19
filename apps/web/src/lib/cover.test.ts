import { describe, expect, it } from 'vitest';
import { coverUrl } from './cover';

describe('coverUrl', () => {
  it('builds the public bucket URL', () => {
    expect(coverUrl('org/camp/cover.webp', 'https://core.example.co/')).toBe(
      'https://core.example.co/storage/v1/object/public/campaign-covers/org/camp/cover.webp',
    );
  });
  it('encodes each segment', () => {
    expect(coverUrl('/o/c/my cover#1.png', 'https://x.co')).toBe('https://x.co/storage/v1/object/public/campaign-covers/o/c/my%20cover%231.png');
  });
  it('returns null without a path or base', () => {
    expect(coverUrl(null, 'https://x.co')).toBeNull();
    expect(coverUrl('a.png', '')).toBeNull();
  });
});
