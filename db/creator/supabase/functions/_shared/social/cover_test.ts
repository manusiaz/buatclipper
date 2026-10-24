import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import { coverHash } from "./cover.ts";

const W = 320, H = 180;
function image(f: (x: number, y: number) => number): Uint8Array {
  const d = new Uint8Array(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const v = f(x, y), i = (y * W + x) * 4;
      d.set([v, (v * 3) % 256, 255 - v, 255], i);
    }
  }
  return d;
}
const scene = image((x, y) => Math.floor(128 + 100 * Math.sin(x / 23) * Math.cos(y / 17)));
const other = image((x, y) => Math.floor(128 + 100 * Math.cos(x / 9 + y / 31)));
const jpg = (data: Uint8Array, quality: number) => jpeg.encode({ data, width: W, height: H }, quality).data;
const serve = (body: Uint8Array) =>
  (() => Promise.resolve(new Response(new Uint8Array(body)))) as unknown as typeof fetch;
const dist = (a: string, b: string) => BigInt.asUintN(64, BigInt(a) ^ BigInt(b)).toString(2).replace(/0/g, "").length;

Deno.test("FR-07 cover: dHash tahan re-encode, beda untuk cover lain; polos/bukan JPEG/bukan https → null", async () => {
  const a = await coverHash("https://cdn.test/a.jpg", serve(jpg(scene, 90)));
  const a2 = await coverHash("https://cdn.test/a2.jpg", serve(jpg(scene, 40)));
  const b = await coverHash("https://cdn.test/b.jpg", serve(jpg(other, 90)));
  assert.ok(a && a2 && b);
  assert.ok(dist(a, a2) <= 6, `re-encode ${dist(a, a2)}`); // = default trust.fraud.cover_distance
  assert.ok(dist(a, b) > 12, `cover lain ${dist(a, b)}`);
  assert.equal(await coverHash("https://cdn.test/flat.jpg", serve(jpg(image(() => 90), 90))), null);
  assert.equal(await coverHash("https://cdn.test/x.png", serve(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))), null);
  assert.equal(await coverHash("http://cdn.test/a.jpg", serve(jpg(scene, 90))), null);
  assert.equal(await coverHash(null), null);
});

Deno.test("FR-07 cover: thumbnail Shorts ber-pillarbox (320×180, isi 101 px di tengah) — bingkai hitam tidak dihitung", async () => {
  const shorts = (f: (x: number, y: number) => number) => {
    const d = new Uint8Array(W * H * 4);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const v = x >= 110 && x < 211 ? Math.max(0, Math.min(255, Math.floor(f(x - 110, y)))) : 0;
        d.set([v, v, v, 255], (y * W + x) * 4);
      }
    }
    return d;
  };
  const a = shorts((x, y) => 128 + 100 * Math.sin(x / 7) * Math.cos(y / 17));
  const b = shorts((x, y) => 128 + 100 * Math.cos(x / 5 + y / 31));
  const c = shorts((x, y) => ((x >> 3) ^ (y >> 4)) & 1 ? 200 : 60);
  const [ha, ha2, hb, hc] = await Promise.all([
    coverHash("https://i.ytimg.com/vi/a/mqdefault.jpg", serve(jpg(a, 95))),
    coverHash("https://i.ytimg.com/vi/a2/mqdefault.jpg", serve(jpg(a, 75))),
    coverHash("https://i.ytimg.com/vi/b/mqdefault.jpg", serve(jpg(b, 90))),
    coverHash("https://i.ytimg.com/vi/c/mqdefault.jpg", serve(jpg(c, 90))),
  ]);
  assert.ok(ha && ha2 && hb && hc);
  assert.ok(dist(ha, ha2) <= 6, `Shorts sama, re-encode ${dist(ha, ha2)}`);
  assert.ok(
    dist(ha, hb) > 20 && dist(ha, hc) > 20 && dist(hb, hc) > 20,
    `Shorts berbeda ${dist(ha, hb)} ${dist(ha, hc)} ${dist(hb, hc)}`,
  );
});
