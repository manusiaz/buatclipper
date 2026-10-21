import { describe, expect, it, vi } from 'vitest';

vi.mock('./env', () => ({ env: { appUrl: 'https://app.clipper.id' } }));
const { nativeRoute, webHref } = await import('./links');

describe('nativeRoute (tap notifikasi / link web → layar native)', () => {
  it('campaign, tab, dan root punya padanan native', () => {
    expect(nativeRoute('https://app.clipper.id/campaigns/e2e00000-0000-0000-0000-0000000000c0?submit=1')).toBe('/campaign/e2e00000-0000-0000-0000-0000000000c0');
    expect(nativeRoute('https://app.clipper.id/wallet?tab=reward')).toBe('/wallet');
    expect(nativeRoute('/tasks')).toBe('/tasks');
    expect(nativeRoute('https://app.clipper.id')).toBe('/');
    expect(nativeRoute('https://app.clipper.id/campaigns')).toBe('/');
  });
  it('halaman tanpa layar native atau host lain → browser', () => {
    expect(nativeRoute('https://app.clipper.id/wallet/withdraw')).toBeNull();
    expect(nativeRoute('https://accounts.clipper.id/kyc')).toBeNull();
    expect(nativeRoute('https://app.clipper.id.evil.com/campaigns/e2e00000-0000-0000-0000-0000000000c0')).toBeNull();
  });
  it('path relatif tanpa layar native dibuka sebagai halaman app.{domain}', () => {
    expect(nativeRoute('/profile')).toBeNull();
    expect(webHref('/profile')).toBe('https://app.clipper.id/profile');
    expect(webHref('https://brand.clipper.id/c/1')).toBe('https://brand.clipper.id/c/1');
  });
});
