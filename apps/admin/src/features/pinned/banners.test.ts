import { describe, expect, it } from 'vitest';
import { validBanners } from './banners';
import { trustScore } from '../users/trust';

describe('validBanners', () => {
  it('accepts https/public images and internal or https links', () => {
    expect(validBanners([{ img: 'banner/1.webp', href: '/campaigns', alt: ' x ' }])).toEqual([{ img: 'banner/1.webp', href: '/campaigns', alt: 'x' }]);
    expect(validBanners([{ img: 'https://cdn.example.com/a.jpg', href: 'https://example.com', alt: '' }])).toHaveLength(1);
    expect(validBanners([])).toEqual([]);
  });
  it('rejects scripts, protocol-relative links and too many banners', () => {
    expect(validBanners([{ img: 'javascript:alert(1)', href: '/', alt: '' }])).toBeNull();
    expect(validBanners([{ img: 'a.png', href: '//evil.example', alt: '' }])).toBeNull();
    expect(validBanners(Array.from({ length: 11 }, () => ({ img: 'a.png', href: '/', alt: '' })))).toBeNull();
    expect(validBanners('x')).toBeNull();
  });
});

describe('trustScore', () => {
  it('50 + Σ delta, clamped 0–100', () => {
    expect(trustScore([])).toBe(50);
    expect(trustScore([1, 1, -2])).toBe(50);
    expect(trustScore([-50, -20])).toBe(0);
    expect(trustScore([60])).toBe(100);
  });
});
