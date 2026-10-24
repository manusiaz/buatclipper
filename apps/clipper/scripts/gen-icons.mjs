// Ikon PWA + app native dari LogoMark (tile gradien biru + pesawat kertas −32°), tanpa dependensi: rasterisasi poligon +
// PNG via zlib. Jalankan: node apps/clipper/scripts/gen-icons.mjs → apps/clipper/public/icons/*.png dan
// apps/mobile/assets/icons/*.png (DS Android 05: 2 layer + monochrome themed; DS iOS 05: terang / gelap / tinted).
import { mkdirSync, writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';

const out = new URL('../public/icons/', import.meta.url);
const native = new URL('../../mobile/assets/icons/', import.meta.url);
mkdirSync(out, { recursive: true });
mkdirSync(native, { recursive: true });

// Glyph "send" (Material Symbols, viewBox 0 -960 960 960) — versi terisi, kurva diratakan.
const PLANE = [
  [162, -178], [120, -205], [120, -405], [422, -480], [120, -557], [120, -755], [162, -782], [814, -508], [832, -480], [814, -452],
];
const STOPS = [
  [0, [0x4d, 0x7d, 0xff]],
  [0.5, [0x1d, 0x5b, 0xff]],
  [1, [0x0f, 0x47, 0xe0]],
];

function crcTable() {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
}
const CRC = crcTable();
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(size, rgba) {
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function inside(poly, x, y) {
  let hit = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i];
    const [xj, yj] = poly[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
}

function gradient(t) {
  const [a, b] = t <= 0.5 ? [STOPS[0], STOPS[1]] : [STOPS[1], STOPS[2]];
  const k = (t - a[0]) / (b[0] - a[0]);
  return a[1].map((v, i) => Math.round(v + (b[1][i] - v) * k));
}

/** opts: glyph = sisi glyph relatif tile (0 = tanpa pesawat), radius = sudut relatif (0 = full-bleed), bg = false →
 *  hanya glyph warna fg di atas transparan. */
function render(size, { glyph, radius, bg = true, fg = [255, 255, 255] }) {
  const S = 4;
  const deg = (-32 * Math.PI) / 180;
  const g = glyph * size;
  const plane = PLANE.map(([px, py]) => {
    // pusat glyph 480,-480 → origin; rotasi −32°; geser 4% kanan, 4% atas (sama dengan LogoMark)
    const x = (px - 480) / 960;
    const y = (py + 480) / 960;
    const rx = x * Math.cos(deg) - y * Math.sin(deg);
    const ry = x * Math.sin(deg) + y * Math.cos(deg);
    return [size / 2 + rx * g + 0.04 * g, size / 2 + ry * g - 0.04 * g];
  });
  const r = radius * size;
  const buf = Buffer.alloc(size * size * 4);
  const ang = (160 * Math.PI) / 180;
  const dir = [Math.sin(ang), -Math.cos(ang)];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let tile = 0;
      let mark = 0;
      for (let sy = 0; sy < S; sy++) {
        for (let sx = 0; sx < S; sx++) {
          const fx = x + (sx + 0.5) / S;
          const fy = y + (sy + 0.5) / S;
          const cx = Math.min(Math.max(fx, r), size - r);
          const cy = Math.min(Math.max(fy, r), size - r);
          if (r === 0 || (fx - cx) ** 2 + (fy - cy) ** 2 <= r * r) tile++;
          if (inside(plane, fx, fy)) mark++;
        }
      }
      const a = tile / (S * S);
      const m = mark / (S * S);
      const i = (y * size + x) * 4;
      if (!bg) {
        buf.set([...fg, Math.round(m * 255)], i);
        continue;
      }
      const t = Math.min(1, Math.max(0, ((x / size - 0.5) * dir[0] + (y / size - 0.5) * dir[1]) / 1.0 + 0.5));
      const [cr, cg, cb] = gradient(t);
      buf.set([Math.round(cr + (255 - cr) * m), Math.round(cg + (255 - cg) * m), Math.round(cb + (255 - cb) * m), Math.round(a * 255)], i);
    }
  }
  return png(size, buf);
}

const files = {
  'icon-192.png': render(192, { glyph: 0.59, radius: 0.3 }),
  'icon-512.png': render(512, { glyph: 0.59, radius: 0.3 }),
  // maskable: full-bleed, glyph di dalam safe zone 80 %
  'maskable-512.png': render(512, { glyph: 0.46, radius: 0 }),
  // iOS membulatkan sudut sendiri dan tidak suka transparan
  'apple-touch-icon.png': render(180, { glyph: 0.55, radius: 0 }),
  // badge notifikasi Android: siluet putih di atas transparan
  'badge-96.png': render(96, { glyph: 0.8, radius: 0, bg: false }),
};
// Native: master 1024. Android adaptive = latar gradien + pesawat putih di zona aman 66/108 dp (juga dipakai sebagai
// layer monochrome themed icon Android 13+). iOS 18: terang full-bleed (sistem memotong sudut), gelap = pesawat biru
// #5F8BFF di atas transparan, tinted = siluet terang grayscale yang diwarnai sistem.
const nativeFiles = {
  'ios-light.png': render(1024, { glyph: 0.55, radius: 0 }),
  'ios-dark.png': render(1024, { glyph: 0.55, radius: 0, bg: false, fg: [0x5f, 0x8b, 0xff] }),
  'ios-tinted.png': render(1024, { glyph: 0.55, radius: 0, bg: false }),
  'android-background.png': render(1024, { glyph: 0, radius: 0 }),
  'android-foreground.png': render(1024, { glyph: 0.42, radius: 0, bg: false }),
};
for (const [name, data] of Object.entries(files)) writeFileSync(new URL(name, out), data);
for (const [name, data] of Object.entries(nativeFiles)) writeFileSync(new URL(name, native), data);
console.log(`icons: ${[...Object.keys(files), ...Object.keys(nativeFiles)].join(', ')}`);
