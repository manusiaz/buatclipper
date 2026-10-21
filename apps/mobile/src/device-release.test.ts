// Keluar di HP bersama: data akun lama tidak boleh tertinggal di widget atau layar kunci (Codex R53).
import { beforeEach, describe, expect, it, vi } from 'vitest';

const store = new Map<string, string>();
let failStorage = 0;
const flaky = <T,>(f: () => T) => async () => (failStorage > 0 ? (failStorage--, Promise.reject(new Error('disk'))) : f());
vi.mock('@react-native-async-storage/async-storage', () => ({
  default: {
    getItem: (k: string) => flaky(() => store.get(k) ?? null)(),
    setItem: (k: string, v: string) => flaky(() => void store.set(k, v))(),
    removeItem: async (k: string) => void store.delete(k),
  },
}));
const jwt = (sub: string) => `x.${Buffer.from(JSON.stringify({ sub })).toString('base64url')}.y`;
let session: { access_token: string } | null = null;
const deleted: string[][] = [];
let deleteError: { message: string } | null = null;
const rpc = vi.fn(async (..._a: unknown[]) => ({ error: null as { message: string } | null }));
let payout: { data: { id: string } | null; error: { message: string } | null } = { data: null, error: null };
type Fake = { getId: () => string; getPushToken: () => Promise<string | null>; addPushTokenListener: () => void; end: ReturnType<typeof vi.fn> };
let instances: Fake[] = [];
vi.mock('./supabase', () => ({
  identity: { auth: { getSession: async () => ({ data: { session } }) } },
  identityApi: { rpc: (...a: unknown[]) => rpc(...(a as [])), from: () => ({ delete: () => ({ in: async (_c: string, v: string[]) => (deleted.push(v), { error: deleteError }) }) }) },
  core: { from: () => ({ select: () => ({ eq: () => ({ eq: () => ({ order: () => ({ limit: () => ({ maybeSingle: async () => payout }) }) }) }) }) }) },
}));
let release: (() => void) | null = null;
vi.mock('./data', () => ({
  widgetData: () => new Promise((ok) => (release = () => ok({ signedIn: true, available: 482000, pending: 0, payout: null, review: 1, campaigns: [] }))),
}));
let onStartToken: ((e: { activityPushToStartToken: string }) => void) | null = null;
vi.mock('expo-widgets', () => ({
  createLiveActivity: () => ({ getInstances: () => instances }),
  addPushToStartTokenListener: (f: typeof onStartToken) => ((onStartToken = f), { remove: () => (onStartToken = null) }),
}));
vi.mock('@expo/ui/swift-ui', () => ({}));
vi.mock('@expo/ui/swift-ui/modifiers', () => ({}));

// Modul dimuat ulang tiap tes: token perangkat & daftar tertaut sengaja bertahan lintas sesi di dalam satu proses app.
let invalidateWidgetSnapshot: typeof import('./widget-load').invalidateWidgetSnapshot;
let loadWidgetSnapshot: typeof import('./widget-load').loadWidgetSnapshot;
let releaseLiveActivities: typeof import('./live-activity.ios').releaseLiveActivities;
let syncLiveActivities: typeof import('./live-activity.ios').syncLiveActivities;

beforeEach(async () => {
  vi.resetModules();
  ({ invalidateWidgetSnapshot, loadWidgetSnapshot } = await import('./widget-load'));
  ({ releaseLiveActivities, syncLiveActivities } = await import('./live-activity.ios'));
  store.clear();
  deleted.length = 0;
  deleteError = null;
  failStorage = 0;
  rpc.mockReset();
  rpc.mockImplementation(async () => ({ error: null }));
  payout = { data: null, error: null };
  instances = [];
  session = { access_token: jwt('user-a') };
});

describe('widget setelah keluar', () => {
  it('muatan yang sedang jalan saat keluar dibuang, tidak menulis snapshot akun lama', async () => {
    const pending = loadWidgetSnapshot();
    await vi.waitFor(() => expect(release).toBeTruthy());
    invalidateWidgetSnapshot();
    session = null;
    release!();
    const s = await pending;
    expect(s.signedIn).toBe(false);
    expect(store.has('clipper.widget.last')).toBe(false);
  });
  it('snapshot cadangan hanya untuk user yang sama', async () => {
    store.set('clipper.widget.last', JSON.stringify({ uid: 'user-b', snap: { signedIn: true, balance: 'Rp9' } }));
    release = null;
    const pending = loadWidgetSnapshot();
    await vi.waitFor(() => expect(release).toBeTruthy());
    release!();
    expect((await pending).balance).toBe('Rp482.000');
    expect(JSON.parse(store.get('clipper.widget.last')!).uid).toBe('user-a');
  });
});

describe('token Live Activity saat keluar', () => {
  it('DELETE gagal → error (keluar dibatalkan), daftar token tetap untuk dicoba lagi', async () => {
    await syncLiveActivities('user-a');
    onStartToken!({ activityPushToStartToken: 'AB12' });
    await vi.waitFor(() => expect(store.get('clipper.apns.tokens')).toBe('["ab12"]'));
    deleteError = { message: 'offline' };
    await expect(releaseLiveActivities()).rejects.toThrow('live_activity_release_failed');
    expect(store.get('clipper.apns.tokens')).toBe('["ab12"]');
    deleteError = null;
    await releaseLiveActivities();
    expect(deleted.at(-1)).toEqual(['ab12']);
    expect(store.has('clipper.apns.tokens')).toBe(false);
  });
  it('simpan bersamaan tidak saling menimpa daftar token (semua ikut dihapus saat keluar)', async () => {
    await syncLiveActivities('user-a');
    onStartToken!({ activityPushToStartToken: 'AA01' });
    onStartToken!({ activityPushToStartToken: 'BB02' });
    await releaseLiveActivities();
    expect(deleted.at(-1)?.sort()).toEqual(['aa01', 'bb02']);
  });
  it('storage gagal sekali: token tetap dihapus saat keluar, pencatatan berikutnya tetap jalan (R55)', async () => {
    await syncLiveActivities('user-a');
    failStorage = 1;
    onStartToken!({ activityPushToStartToken: 'CC03' });
    await vi.waitFor(() => expect(rpc).toHaveBeenCalledTimes(1));
    onStartToken!({ activityPushToStartToken: 'DD04' });
    await vi.waitFor(() => expect(store.get('clipper.apns.tokens')).toContain('dd04'));
    await releaseLiveActivities();
    expect(deleted.at(-1)?.sort()).toEqual(['cc03', 'dd04']);
  });
  it('daftar tersimpan tak terbaca saat keluar → batal keluar, daftar tetap ada (R56)', async () => {
    store.set('clipper.apns.tokens', '["ee05"]');
    failStorage = 1;
    await expect(releaseLiveActivities()).rejects.toThrow('live_activity_release_failed');
    expect(store.get('clipper.apns.tokens')).toBe('["ee05"]');
    await releaseLiveActivities();
    expect(deleted.at(-1)).toEqual(['ee05']);
  });
  it('pendaftaran push-to-start gagal dicoba lagi oleh poll tanpa event token baru (R57)', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
    try {
      rpc.mockImplementationOnce(async () => ({ error: { message: 'offline' } }));
      await syncLiveActivities('user-a');
      onStartToken!({ activityPushToStartToken: 'FF06' });
      await vi.waitFor(() => expect(rpc).toHaveBeenCalledTimes(1));
      await vi.advanceTimersByTimeAsync(30_000);
      await vi.waitFor(() => expect(store.get('clipper.apns.tokens')).toBe('["ff06"]'));
      expect(rpc).toHaveBeenCalledTimes(2);
      // Akun lain login setelah keluar: token perangkat yang sama didaftarkan ulang tanpa event native baru.
      await releaseLiveActivities();
      rpc.mockClear();
      await syncLiveActivities('user-b');
      await vi.waitFor(() => expect(rpc).toHaveBeenCalledWith('save_activity_token', { p_token: 'FF06', p_kind: 'apns_start' }));
      await releaseLiveActivities();
    } finally {
      vi.useRealTimers();
    }
  });
  it('token yang datang saat/selesai keluar tidak didaftarkan ulang ke akun lama', async () => {
    await syncLiveActivities('user-a');
    const listener = onStartToken!;
    await releaseLiveActivities();
    expect(onStartToken).toBeNull();
    listener({ activityPushToStartToken: 'CD34' });
    expect(rpc).not.toHaveBeenCalled();
  });
});

describe('menautkan activity yang dimulai push (R54)', () => {
  const activity = (id: string): Fake => ({ getId: () => id, getPushToken: async () => 'EF56', addPushTokenListener: () => {}, end: vi.fn(async () => {}) });

  it('simpan token gagal → dicoba lagi di sinkronisasi berikutnya', async () => {
    payout = { data: { id: 'p-1' }, error: null };
    instances = [activity('a-1')];
    rpc.mockImplementationOnce(async () => ({ error: { message: 'offline' } }));
    await syncLiveActivities('user-a');
    await syncLiveActivities('user-a');
    const calls = rpc.mock.calls.filter((c) => (c[1] as { p_kind: string }).p_kind === 'apns_activity');
    expect(calls).toHaveLength(2);
    expect(calls[1]![1]).toMatchObject({ p_token: 'EF56', p_ref: 'p-1' });
    await releaseLiveActivities();
  });

  it('query payout gagal (offline) tidak mengakhiri activity', async () => {
    const a = activity('a-2');
    instances = [a];
    payout = { data: null, error: { message: 'offline' } };
    await syncLiveActivities('user-a');
    expect(a.end).not.toHaveBeenCalled();
    payout = { data: null, error: null };
    await syncLiveActivities('user-a');
    expect(a.end).toHaveBeenCalledWith('default');
    await releaseLiveActivities();
  });

  it('penghenti dari sync lama tidak mematikan listener sync yang lebih baru', async () => {
    const oldStop = await syncLiveActivities('user-a');
    await syncLiveActivities('user-a');
    oldStop();
    expect(onStartToken).not.toBeNull();
    await releaseLiveActivities();
  });
});
