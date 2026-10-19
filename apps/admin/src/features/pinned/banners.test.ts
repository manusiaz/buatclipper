import { describe, expect, it } from 'vitest';
import { validBanners } from './banners';

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
