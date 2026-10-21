// Live Activity "Payout" (DS iOS 05 Dynamic Island & Motion 26 #4: "Lagi ditransfer Rp482rb · BCA •• 4821 · ±2 menit"):
// dimulai server lewat APNs push-to-start saat payout.processing dan diakhiri saat paid/failed/cancelled
// (db/identity/.../_shared/apns.ts). App hanya mendaftarkan layout + token: push-to-start (apns_start) dan token update
// tiap activity (apns_activity, ref = payout yang sedang diproses). Teks Indonesia seperti notifikasi server.
import { HStack, Image, ProgressView, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { activityBackgroundTint, font, foregroundStyle, lineLimit, monospacedDigit } from '@expo/ui/swift-ui/modifiers';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { addPushToStartTokenListener, createLiveActivity, type LiveActivityEnvironment } from 'expo-widgets';
import { core, identityApi } from './supabase';

export type PayoutActivity = { payoutId?: string; amount?: number; bank?: string | null; last4?: string | null; etaAt?: string | null; startedAt?: string | null; status?: string };

const Payout = createLiveActivity<PayoutActivity>('Payout', (p: PayoutActivity, env: LiveActivityEnvironment) => {
  'widget';
  // Tanpa regex ber-backslash: plugin 'widget' menjadikan fungsi ini template string, backslash ikut hilang.
  const n = Math.round(Number(p.amount) || 0);
  const digits = String(n);
  let grouped = '';
  for (let i = 0; i < digits.length; i++) grouped += (i > 0 && (digits.length - i) % 3 === 0 ? '.' : '') + digits[i];
  const full = 'Rp' + grouped;
  const short = n >= 1e6 ? 'Rp' + (n / 1e6).toFixed(1).replace('.', ',').replace(',0', '') + 'jt' : n >= 1e3 ? 'Rp' + Math.round(n / 1e3) + 'rb' : full;
  const bank = p.bank ? String(p.bank).split('_').join(' ').toUpperCase() + (p.last4 ? ' •• ' + p.last4 : '') : '';
  const done = p.status === 'paid';
  const failed = p.status === 'failed';
  // Lewat stale-date tanpa kabar akhir (activity tak tertaut karena app tertutup): jangan terus bilang "lagi ditransfer".
  const stale = !done && !failed && !!env.isStale;
  const title = done ? 'Sudah masuk' : failed ? 'Transfer gagal' : stale ? 'Cek status di Clipper' : 'Lagi ditransfer';
  const start = p.startedAt ? new Date(p.startedAt) : new Date();
  const eta = p.etaAt ? new Date(p.etaAt) : null;
  const running = !done && !failed && !stale && eta && eta.getTime() > Date.now();
  const icon = done ? 'checkmark.circle.fill' : failed ? 'exclamationmark.circle.fill' : stale ? 'clock.fill' : 'paperplane.fill';
  const tint = done ? '#22c55e' : failed ? '#ef4444' : stale ? '#c7cede' : '#5f8bff';
  const progress = running ? (
    <ProgressView timerInterval={{ lower: start, upper: eta! }} countsDown={false} modifiers={[foregroundStyle(tint)]} />
  ) : null;
  const sub = [bank, failed ? 'saldo kembali ke wallet' : stale ? 'buka app untuk status terbaru' : null].filter(Boolean).join(' · ');
  return {
    banner: (
      <VStack alignment="leading" spacing={6} modifiers={[activityBackgroundTint('#0a1226')]}>
        <HStack spacing={10}>
          <Image systemName={icon} size={22} color={tint} />
          <VStack alignment="leading" spacing={2}>
            <Text modifiers={[font({ textStyle: 'caption', weight: 'semibold' }), foregroundStyle('#c7cede')]}>{'Clipper · ' + title}</Text>
            <Text modifiers={[font({ size: 26, weight: 'bold', design: 'rounded' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{full}</Text>
          </VStack>
          <Spacer />
          {running ? <Text timerInterval={{ lower: new Date(), upper: eta! }} countsDown modifiers={[font({ textStyle: 'subheadline', weight: 'semibold' }), foregroundStyle('#ffffff'), monospacedDigit()]} /> : null}
        </HStack>
        {progress}
        {sub ? <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede'), lineLimit(1)]}>{sub}</Text> : null}
      </VStack>
    ),
    compactLeading: <Image systemName={icon} color={tint} />,
    compactTrailing: <Text modifiers={[font({ textStyle: 'caption', weight: 'bold' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{short}</Text>,
    minimal: <Image systemName={icon} color={tint} />,
    expandedLeading: (
      <VStack alignment="leading" spacing={2}>
        <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede')]}>{title}</Text>
        <Text modifiers={[font({ textStyle: 'title3', weight: 'bold' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{short}</Text>
      </VStack>
    ),
    expandedTrailing: running ? (
      <Text timerInterval={{ lower: new Date(), upper: eta! }} countsDown modifiers={[font({ textStyle: 'subheadline', weight: 'semibold' }), foregroundStyle('#ffffff'), monospacedDigit()]} />
    ) : (
      <Image systemName={icon} size={22} color={tint} />
    ),
    expandedBottom: (
      <VStack alignment="leading" spacing={4}>
        {progress}
        {sub ? <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede'), lineLimit(1)]}>{sub}</Text> : null}
      </VStack>
    ),
  };
});

const SAVED = 'clipper.apns.tokens';

// Serial: dua simpan bersamaan (push-to-start + token activity) tidak boleh saling menimpa daftar — token yang hilang
// dari daftar tidak ikut dihapus saat keluar.
// Juga dicatat di memori: storage gagal tidak membuat token terdaftar lolos dari penghapusan saat keluar, dan antrean
// pulih sebelum tiap operasi (satu kegagalan tidak menghentikan pencatatan berikutnya).
const known = new Set<string>();
let remembering: Promise<void> = Promise.resolve();
function remember(token: string) {
  known.add(token);
  const next = remembering
    .catch(() => {})
    .then(async () => {
      const list = JSON.parse((await AsyncStorage.getItem(SAVED)) ?? '[]') as string[];
      if (!list.includes(token)) await AsyncStorage.setItem(SAVED, JSON.stringify([...list, token].slice(-20)));
    });
  remembering = next;
  return next.catch(() => {});
}

// Keluar (releaseLiveActivities) menutup pendaftaran dulu: listener & poll dihentikan, simpan yang sedang jalan ditunggu,
// baru DELETE — token tidak bisa didaftarkan ulang ke akun lama di tengah proses keluar.
let released = false;
let startSub: { remove(): void } | null = null;
let poll: ReturnType<typeof setInterval> | null = null;
let generation = 0;
const inflight = new Set<Promise<unknown>>();
const linked = new Set<string>();

/** true = tersimpan di identity. Dilacak supaya keluar menunggu simpan yang sedang jalan. */
function save(token: string, kind: 'apns_start' | 'apns_activity', ref?: string): Promise<boolean> {
  if (released) return Promise.resolve(false);
  const run: Promise<boolean> = (async () => {
    const { error } = await identityApi.rpc('save_activity_token', { p_token: token, p_kind: kind, ...(ref ? { p_ref: ref } : {}) });
    if (error) return false;
    await remember(token.toLowerCase());
    return true;
  })()
    .catch(() => false)
    .finally(() => inflight.delete(run));
  inflight.add(run);
  return run;
}

/** Tautkan activity yang belum ditautkan ke payout yang sedang diproses (props activity tak terbaca dari JS). Baru
 *  dianggap tertaut setelah token tersimpan — gagal (offline) dicoba lagi di poll berikutnya. Query gagal ≠ tak ada
 *  payout: activity hanya diakhiri bila core menjawab tidak ada payout yang diproses. */
async function link(uid: string) {
  const fresh = Payout.getInstances().filter((a) => !linked.has(a.getId()));
  if (!fresh.length || released) return;
  fresh.forEach((a) => linked.add(a.getId()));
  const unlink = () => fresh.forEach((a) => linked.delete(a.getId()));
  const { data, error } = await core.from('payouts').select('id').eq('user_id', uid).eq('status', 'processing').order('created_at', { ascending: false }).limit(1).maybeSingle().then(
    (r) => r,
    () => ({ data: null, error: true }),
  );
  if (error) return unlink();
  await Promise.all(
    fresh.map(async (a) => {
      const id = a.getId();
      if (!data?.id) return a.end('default');
      const token = await a.getPushToken().catch(() => null);
      if (token) return void ((await save(token, 'apns_activity', data.id)) || linked.delete(id));
      a.addPushTokenListener((e) => void save(e.pushToken, 'apns_activity', data.id!).then((ok) => ok || linked.delete(id)));
    }),
  );
}

function stop() {
  startSub?.remove();
  startSub = null;
  if (poll) clearInterval(poll);
  poll = null;
}

/**
 * Saat login / app aktif: daftar token push-to-start, tautkan activity yang tampil, lalu cek tiap 30 detik selama app
 * aktif — activity yang dimulai push setelah ini juga dapat token update (supaya server bisa mengakhirinya). Activity
 * yang tak sempat ditautkan (app tertutup terus) jadi "basi" setelah stale-date dan tampil jujur di layout.
 */
export async function syncLiveActivities(uid: string): Promise<() => void> {
  released = false;
  stop();
  const mine = ++generation;
  startSub = addPushToStartTokenListener((e) => void save(e.activityPushToStartToken, 'apns_start'));
  poll = setInterval(() => void link(uid).catch(() => {}), 30_000);
  await link(uid).catch(() => {});
  // Penghenti milik run ini saja: callback run lama yang selesai terlambat tidak mematikan run yang lebih baru.
  return () => void (mine === generation && stop());
}

/**
 * Keluar: hapus token APNs perangkat ini selagi masih login. Berbeda dengan push Expo (token dicabut lewat unregister),
 * token push-to-start tidak bisa dicabut dari app — jadi gagal hapus (offline) = lempar error dan keluar dibatalkan,
 * supaya pencairan akun ini tidak muncul di layar kunci setelah orang lain memakai HP ini.
 */
export async function releaseLiveActivities() {
  released = true;
  generation++;
  stop();
  await Promise.allSettled([...inflight]);
  await remembering.catch(() => {});
  const fail = () => {
    released = false;
    return new Error('live_activity_release_failed');
  };
  // Daftar tersimpan tak terbaca = tidak tahu token mana yang terdaftar (setelah restart memori kosong) → batal keluar.
  const stored = await AsyncStorage.getItem(SAVED).then(
    (v) => JSON.parse(v ?? '[]') as string[],
    () => null,
  );
  if (!stored) throw fail();
  const list = [...new Set([...stored, ...known])];
  if (list.length) {
    const { error } = await identityApi.from('push_subscriptions').delete().in('endpoint', list);
    if (error) throw fail();
  }
  await AsyncStorage.removeItem(SAVED).catch(() => {});
  known.clear();
  linked.clear();
  await Promise.all(Payout.getInstances().map((a) => a.end('immediate')));
}
