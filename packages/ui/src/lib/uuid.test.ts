import { afterEach, describe, expect, it, vi } from 'vitest';
import { randomId } from './uuid';

describe('randomId', () => {
  afterEach(() => vi.unstubAllGlobals());
  it('tanpa crypto.randomUUID (http) tetap UUID v4', () => {
    const real = globalThis.crypto;
    vi.stubGlobal('crypto', { getRandomValues: (a: Uint8Array) => real.getRandomValues(a) });
    const ids = new Set(Array.from({ length: 50 }, randomId));
    expect(ids.size).toBe(50);
    for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });
});
