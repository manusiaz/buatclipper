import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';

// public/sw.js dijalankan di sandbox dengan `self` tiruan: push → notifikasi (+ aksi, badge), klik aksi → URL aksi.
function loadSw() {
  const handlers: Record<string, (e: unknown) => void> = {};
  const shown: Array<{ title: string; opts: Record<string, unknown> }> = [];
  const opened: string[] = [];
  const badge = { set: 0, clear: 0 };
  const self = {
    location: new URL('https://app.clipper.test/sw.js'),
    addEventListener: (type: string, fn: (e: unknown) => void) => (handlers[type] = fn),
    registration: { showNotification: async (title: string, opts: Record<string, unknown>) => void shown.push({ title, opts }) },
    navigator: { setAppBadge: async () => void badge.set++, clearAppBadge: async () => void badge.clear++ },
    clients: { matchAll: async () => [], openWindow: async (u: string) => void opened.push(u) },
    skipWaiting: () => {},
  };
  runInNewContext(readFileSync(join(__dirname, '../../../public/sw.js'), 'utf8'), { self, URL, caches: {}, fetch });
  const fire = async (type: string, event: Record<string, unknown>) => {
    let done: Promise<unknown> = Promise.resolve();
    handlers[type]!({ ...event, waitUntil: (p: Promise<unknown>) => (done = p) });
    await done;
  };
  return { fire, shown, opened, badge };
}

describe('sw.js push actions & badge', () => {
  it('approve: 2 tombol aksi, badge dipasang, klik "wallet" membuka URL aksinya', async () => {
    const sw = loadSw();
    const payload = {
      title: 'Submisi kamu disetujui',
      body: 'Views-nya sekarang dihitung.',
      url: 'https://app.clipper.test/tasks',
      actions: [
        { action: 'wallet', title: 'Lihat saldo', url: 'https://app.clipper.test/wallet' },
        { action: 'campaign', title: 'Kirim clip lagi', url: 'https://app.clipper.test/campaigns/c1' },
        { action: 'extra', title: 'Dibuang', url: 'https://app.clipper.test/x' },
      ],
    };
    await sw.fire('push', { data: { json: () => payload } });
    const n = sw.shown[0]!;
    expect(n.title).toBe('Submisi kamu disetujui');
    expect(n.opts.actions).toEqual([
      { action: 'wallet', title: 'Lihat saldo' },
      { action: 'campaign', title: 'Kirim clip lagi' },
    ]);
    expect(sw.badge.set).toBe(1);

    await sw.fire('notificationclick', { action: 'wallet', notification: { close: () => {}, data: n.opts.data } });
    expect(sw.opened).toEqual(['https://app.clipper.test/wallet']);
    expect(sw.badge.clear).toBe(1);

    await sw.fire('notificationclick', { action: '', notification: { close: () => {}, data: n.opts.data } });
    expect(sw.opened[1]).toBe('https://app.clipper.test/tasks');
  });

  it('URL aksi http asing dibuang ke /campaigns, payload tanpa aksi tetap tampil', async () => {
    const sw = loadSw();
    await sw.fire('push', {
      data: { json: () => ({ title: 'X', url: '/wallet', actions: [{ action: 'a', title: 'A', url: 'http://evil.test/' }] }) },
    });
    await sw.fire('notificationclick', { action: 'a', notification: { close: () => {}, data: sw.shown[0]!.opts.data } });
    expect(sw.opened).toEqual(['https://app.clipper.test/campaigns']);
    await sw.fire('push', { data: { json: () => ({ title: 'Payout' }) } });
    expect(sw.shown[1]!.opts.actions).toEqual([]);
  });
});
