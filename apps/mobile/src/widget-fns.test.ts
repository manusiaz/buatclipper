// Fungsi 'widget' (widget iOS & Live Activity) dikirim sebagai string dan dijalankan extension iOS tanpa kode app:
// kompilasi file dengan babel-preset-expo (iOS, seperti Metro), ambil string yang diserahkan ke expo-widgets, lalu
// jalankan di context terpisah yang hanya berisi global runtime widget. Menangkap referensi ke scope modul dan
// backslash yang hilang saat stringify (regex \d jadi "d").
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it } from 'vitest';

const req = createRequire(import.meta.url);
const expo = req.resolve('expo/package.json');
const babel = req(req.resolve('@babel/core', { paths: [expo] })) as { transformFileSync: (file: string, opts: object) => { code?: string | null } | null };
const preset = req.resolve('babel-preset-expo', { paths: [expo] });

/** name → string fungsi yang diterima createWidget / createLiveActivity. */
function widgetSources(file: string): Record<string, string> {
  const filename = fileURLToPath(new URL(file, import.meta.url).href);
  const out = babel.transformFileSync(filename, {
    babelrc: false,
    configFile: false,
    presets: [preset],
    caller: { name: 'metro', platform: 'ios', isDev: false, bundler: 'metro' } as never,
  })!;
  const found: Record<string, string> = {};
  const capture = (name: string, src: string) => ((found[name] = src), new Proxy({}, { get: () => () => {} }));
  const stub = (id: string) => (id === 'expo-widgets' ? { createWidget: capture, createLiveActivity: capture, addPushToStartTokenListener: () => ({ remove() {} }) } : new Proxy({}, { get: () => () => {} }));
  const module = { exports: {} };
  vm.runInNewContext(out.code!, { require: stub, module, exports: module.exports, process: { env: {} } });
  return found;
}

type Node = { type: string; props: Record<string, unknown> };
const runtime = () => {
  const ctx: Record<string, unknown> = { Date, Math, Number, String };
  for (const c of ['VStack', 'HStack', 'Text', 'Spacer', 'Link', 'Image', 'ProgressView']) ctx[c] = (props: object) => ({ type: c, props });
  for (const m of ['containerBackground', 'widgetURL', 'font', 'foregroundStyle', 'minimumScaleFactor', 'lineLimit', 'padding', 'activityBackgroundTint', 'monospacedDigit']) ctx[m] = (...a: unknown[]) => ({ m, a });
  ctx._jsx = ctx._jsxs = (t: (p: object) => Node, p: object) => t(p);
  return ctx;
};
const run = (src: string, ...args: unknown[]) => (vm.runInNewContext(`(${src})`, runtime()) as (...a: unknown[]) => unknown)(...args);
const texts = (n: unknown, out: string[] = []): string[] => {
  if (Array.isArray(n)) n.forEach((x) => texts(x, out));
  else if (n && typeof n === 'object') {
    const { type, props } = n as Node;
    if (type === 'Text' && typeof props.children === 'string') out.push(props.children);
    if (type === 'Link') out.push(`→${props.destination as string}`);
    texts(props.children, out);
  }
  return out;
};

describe("fungsi 'widget' mandiri (dijalankan extension iOS)", () => {
  const w = widgetSources('./widget.ios.tsx');
  const la = widgetSources('./live-activity.ios.tsx');
  const snap = { signedIn: true, titleShort: 'Saldo', balanceShort: 'Rp482.000', release: 'Cair Senin · BCA •• 4821', reviewLabel: 'Review', reviewLine: '2 clip nunggu approve', forYou: 'Campaign baru buat kamu', empty: '-', campaigns: [{ title: 'Arena', sub: 'Game', rate: 'Rp2.000/1K', url: 'clipper://campaign/a' }] };

  it('widget small & medium hanya memakai global runtime', () => {
    expect(Object.keys(w).sort()).toEqual(['ClipperBalance', 'ClipperCampaigns']);
    expect(texts(run(w.ClipperBalance!, snap, {}))).toEqual(['Saldo', 'Rp482.000', 'Cair Senin · BCA •• 4821']);
    expect(texts(run(w.ClipperBalance!, {}, {}))).toEqual(['Clipper', '—', '']);
    expect(texts(run(w.ClipperCampaigns!, snap, { colorScheme: 'dark' }))).toEqual(['→clipper://clips', 'Review', '2 clip nunggu approve', 'Campaign baru buat kamu', '→clipper://campaign/a', 'Arena', 'Game', 'Rp2.000/1K']);
  });

  it('Live Activity Payout: nominal, rekening, status dari payload APNs', () => {
    const now = Date.now();
    const live = run(la.Payout!, { amount: 482000, bank: 'bca', last4: '4821', status: 'processing', startedAt: new Date(now).toISOString(), etaAt: new Date(now + 120_000).toISOString() }, {}) as Record<string, unknown>;
    expect(Object.keys(live).sort()).toEqual(['banner', 'compactLeading', 'compactTrailing', 'expandedBottom', 'expandedLeading', 'expandedTrailing', 'minimal']);
    expect(texts(live.banner)).toEqual(['Clipper · Lagi ditransfer', 'Rp482.000', 'BCA •• 4821']);
    expect(texts(live.compactTrailing)).toEqual(['Rp482rb']);
    // Lewat stale-date tanpa event end: tidak lagi mengaku "lagi ditransfer".
    const stale = run(la.Payout!, { amount: 482000, bank: 'bca', last4: '4821', status: 'processing', etaAt: new Date(now - 60_000).toISOString() }, { isStale: true }) as Record<string, unknown>;
    expect(texts(stale.banner)).toEqual(['Clipper · Cek status di Clipper', 'Rp482.000', 'BCA •• 4821 · buka app untuk status terbaru']);
    const paid = run(la.Payout!, { amount: 1250000, bank: 'gopay', status: 'paid' }, {}) as Record<string, unknown>;
    expect(texts(paid.banner)).toEqual(['Clipper · Sudah masuk', 'Rp1.250.000', 'GOPAY']);
  });
});
