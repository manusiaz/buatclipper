import { describe, expect, it, vi } from 'vitest';

vi.stubEnv('NEXT_PUBLIC_APP_URL', 'https://app.clipper.test');
vi.stubEnv('NEXT_PUBLIC_ACCOUNTS_URL', 'https://accounts.clipper.test');
vi.stubEnv('NEXT_PUBLIC_BRAND_URL', 'https://brand.clipper.test');
vi.stubEnv('NEXT_PUBLIC_WEB_URL', 'https://clipper.test');
vi.stubEnv('NEXT_PUBLIC_ADMIN_URL', 'https://admin.clipper.test');
const { handoffTarget } = await import('./handoff');

const CODE = 'A'.repeat(43);
const ok = (data: unknown) => () => Promise.resolve({ ok: true as const, data: data as { token_hash?: unknown; next?: unknown } });
const login = (next: string) => `/login?next=${encodeURIComponent(next)}`;

describe('handoffTarget (/handoff)', () => {
  it('kode sah → verifyOtp dengan token_hash dari identity, lalu ke next', async () => {
    const verify = vi.fn(() => Promise.resolve(true));
    const redeem = vi.fn(ok({ token_hash: 'th-1', next: 'https://app.clipper.test/wallet' }));
    expect(await handoffTarget(CODE, null, { redeem, verify })).toBe('https://app.clipper.test/wallet');
    expect(redeem).toHaveBeenCalledWith(CODE);
    expect(verify).toHaveBeenCalledWith('th-1');
  });

  it('next dari identity tetap lewat safeNext (admin / host luar → fallback app)', async () => {
    const verify = () => Promise.resolve(true);
    expect(await handoffTarget(CODE, null, { redeem: ok({ token_hash: 't', next: 'https://admin.clipper.test/' }), verify }))
      .toBe('https://app.clipper.test/campaigns');
    expect(await handoffTarget(CODE, null, { redeem: ok({ token_hash: 't', next: 'https://evil.test/' }), verify }))
      .toBe('https://app.clipper.test/campaigns');
  });

  it('gagal apa pun → /login?next=hint tanpa detail; kode cacat tidak memanggil identity', async () => {
    const redeem = vi.fn(ok({ token_hash: 't', next: 'https://app.clipper.test/x' }));
    const verify = vi.fn(() => Promise.resolve(true));
    const hint = 'https://app.clipper.test/wallet';
    for (const bad of [null, '', 'short', `${CODE}x`, `${'A'.repeat(42)}/`]) {
      expect(await handoffTarget(bad, hint, { redeem, verify })).toBe(login(hint));
    }
    expect(redeem).not.toHaveBeenCalled();
    const fails = [
      { redeem: () => Promise.resolve({ ok: false as const, error: 'invalid_code', status: 400 }), verify },
      { redeem: () => Promise.reject(new Error('network')), verify },
      { redeem: ok({ next: hint }), verify },
      { redeem: ok({ token_hash: 't', next: hint }), verify: () => Promise.resolve(false) },
      { redeem: ok({ token_hash: 't', next: hint }), verify: () => Promise.reject(new Error('otp')) },
    ];
    for (const deps of fails) {
      const to = await handoffTarget(CODE, 'https://evil.test/', deps);
      expect(to).toBe(login('https://app.clipper.test/campaigns'));
      expect(to).not.toMatch(/invalid_code|network|otp/);
    }
  });
});
