// FR-07 (§12): dHash 64-bit cover video — perseptual, jadi cover yang sama dari unggahan lain (byte berbeda, re-encode) tetap
// berjarak Hamming kecil. Cover = thumbnail dari API platform (JPEG); format lain / gagal unduh → null (submit tidak terhambat).
import jpeg from "jpeg-js";

const MAX_BYTES = 2 * 1024 * 1024;

/** RGBA w×h → abu-abu 9×8 (rata-rata kotak) → bit = piksel lebih terang dari tetangga kanan. Hasil int64 bertanda (bigint SQL). */
export function dHash(rgba: Uint8Array, w: number, h: number): bigint {
  const g: number[] = [];
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 9; x++) {
      const [x0, x1] = [Math.floor((x * w) / 9), Math.max(Math.floor(((x + 1) * w) / 9), Math.floor((x * w) / 9) + 1)];
      const [y0, y1] = [Math.floor((y * h) / 8), Math.max(Math.floor(((y + 1) * h) / 8), Math.floor((y * h) / 8) + 1)];
      let sum = 0;
      for (let yy = y0; yy < y1; yy++) {
        for (let xx = x0; xx < x1; xx++) {
          const i = (yy * w + xx) * 4;
          sum += 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
        }
      }
      g.push(Math.round(sum / ((x1 - x0) * (y1 - y0)))); // 8-bit: cover polos → 0, bukan derau float
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
    const img = jpeg.decode(buf, { useTArray: true, maxResolutionInMP: 20, maxMemoryUsageInMB: 128 });
    const h = dHash(img.data, img.width, img.height);
    const ones = BigInt.asUintN(64, h).toString(2).replace(/0/g, "").length;
    return ones < 8 || ones > 56 ? null : h.toString();
  } catch {
    return null;
  }
}
