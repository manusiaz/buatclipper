// FR-07 (§12): dHash 64-bit cover video — perseptual, jadi cover yang sama dari unggahan lain (byte berbeda, re-encode) tetap
// berjarak Hamming kecil. Bingkai polos (pillarbox Shorts 320×180) dibuang dulu supaya bit hanya dari isi video.
// Cover = thumbnail dari API platform (JPEG); format lain / gagal unduh → null (submit tidak terhambat).
import jpeg from "jpeg-js";

const MAX_BYTES = 2 * 1024 * 1024;

/** Luminans per piksel + kotak konten setelah bingkai polos (pillarbox/letterbox Shorts, border) di tepi dibuang. */
function contentBox(rgba: Uint8Array, w: number, h: number) {
  const lum = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) lum[i] = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
  // Garis tepi polos: semua pikselnya dalam rentang 24 dan dekat warna garis terluar (sisi itu).
  const flat = (at: (k: number) => number, n: number, edge: number) => {
    let lo = 255, hi = 0, sum = 0;
    for (let k = 0; k < n; k++) (lo = Math.min(lo, at(k))), (hi = Math.max(hi, at(k))), (sum += at(k));
    return hi - lo <= 24 && Math.abs(sum / n - edge) <= 16;
  };
  const colMean = (x: number) => [...Array(h).keys()].reduce((t, y) => t + lum[y * w + x], 0) / h;
  const rowMean = (y: number) => [...Array(w).keys()].reduce((t, x) => t + lum[y * w + x], 0) / w;
  let [x0, x1, y0, y1] = [0, w, 0, h];
  const l = colMean(0), r = colMean(w - 1);
  while (x0 < w / 2 && flat((y) => lum[y * w + x0], h, l)) x0++;
  while (x1 > x0 + 1 && x1 > w / 2 && flat((y) => lum[y * w + x1 - 1], h, r)) x1--;
  const t = rowMean(0), b = rowMean(h - 1);
  while (y0 < h / 2 && flat((x) => lum[y0 * w + x0 + x], x1 - x0, t)) y0++;
  while (y1 > y0 + 1 && y1 > h / 2 && flat((x) => lum[(y1 - 1) * w + x0 + x], x1 - x0, b)) y1--;
  return { lum, x0, y0, cw: x1 - x0, ch: y1 - y0 };
}

/**
 * RGBA w×h → kotak konten → abu-abu 9×8 (rata-rata kotak, dibulatkan 8-bit) → bit = piksel lebih terang dari tetangga kanan.
 * Hasil int64 bertanda (bigint SQL); null kalau konten terlalu kecil (cover hampir polos).
 */
export function dHash(rgba: Uint8Array, w: number, h: number): bigint | null {
  const { lum, x0, y0, cw, ch } = contentBox(rgba, w, h);
  if (cw < 18 || ch < 16) return null;
  const g: number[] = [];
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 9; x++) {
      const [a0, a1] = [Math.floor((x * cw) / 9), Math.floor(((x + 1) * cw) / 9)];
      const [b0, b1] = [Math.floor((y * ch) / 8), Math.floor(((y + 1) * ch) / 8)];
      let sum = 0;
      for (let yy = b0; yy < b1; yy++) for (let xx = a0; xx < a1; xx++) sum += lum[(y0 + yy) * w + x0 + xx];
      g.push(Math.round(sum / ((a1 - a0) * (b1 - b0))));
    }
  }
  let v = 0n;
  for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) v = (v << 1n) | (g[y * 9 + x] > g[y * 9 + x + 1] ? 1n : 0n);
  return BigInt.asIntN(64, v);
}

/** Hash cover dari URL https; cover polos (hampir semua bit sama) tidak dipakai supaya tidak cocok dengan semua cover polos. */
export async function coverHash(url: string | null, fetchFn: typeof fetch = fetch): Promise<string | null> {
  if (!url?.startsWith("https://")) return null;
  try {
    const res = await fetchFn(url, { signal: AbortSignal.timeout(5000), redirect: "follow" });
    if (!res.ok || Number(res.headers.get("content-length") ?? 0) > MAX_BYTES) return null;
    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.length > MAX_BYTES || buf[0] !== 0xff || buf[1] !== 0xd8) return null; // bukan JPEG
    const img = jpeg.decode(buf, { useTArray: true, maxResolutionInMP: 4, maxMemoryUsageInMB: 64 });
    const h = dHash(img.data, img.width, img.height);
    if (h === null) return null;
    const ones = BigInt.asUintN(64, h).toString(2).replace(/0/g, "").length;
    return ones < 8 || ones > 56 ? null : h.toString();
  } catch {
    return null;
  }
}
