import assert from "node:assert/strict";
import { BridgeError, callBridge, signBridge, verifyBridge } from "./bridge.ts";
import { hmacHex, HttpError } from "./http.ts";
import { jsonRes, mockFetch } from "./testing.ts";

const SECRET = "identity-to-core-secret";
const now = 1_790_000_000;

async function signed(body: string, ts = now, secret = SECRET, sig?: string) {
  return new Request("https://core.test/functions/v1/bridge", {
    method: "POST",
    headers: { "x-bridge-ts": String(ts), "x-bridge-sig": sig ?? await signBridge(secret, ts, body) },
    body,
  });
}

const code = (c: string) => (e: unknown) => e instanceof HttpError && e.code === c;

Deno.test("bridge: tanda tangan = hex HMAC-SHA256(secret, ts.body) (vektor uji)", async () => {
  // Vektor dihitung independen: printf '1790000000.{"v":1}' | openssl dgst -sha256 -hmac identity-to-core-secret
  assert.equal(
    await signBridge(SECRET, now, '{"v":1}'),
    "e1eec6f057555432466f9a27c2cd1cbde9ac64456971069b4f95d865fbb82397",
  );
  assert.equal(
    await hmacHex(SECRET, `${now}.{"v":1}`),
    "e1eec6f057555432466f9a27c2cd1cbde9ac64456971069b4f95d865fbb82397",
  );
  assert.match(await signBridge(SECRET, now, "{}"), /^[0-9a-f]{64}$/);
});

Deno.test("bridge: verifikasi sukses mengembalikan pesan", async () => {
  const body = JSON.stringify({ v: 1, action: "get_batch", payload: { batch_id: "b1" } });
  const msg = await verifyBridge(await signed(body), SECRET, now + 299);
  assert.deepEqual(msg, { v: 1, action: "get_batch", payload: { batch_id: "b1" } });
});

Deno.test("bridge: ditolak kalau lewat 300 detik (masa lalu & masa depan)", async () => {
  const body = JSON.stringify({ v: 1, action: "get_batch", payload: {} });
  await assert.rejects(verifyBridge(await signed(body, now - 301), SECRET, now), code("expired"));
  await assert.rejects(verifyBridge(await signed(body, now + 301), SECRET, now), code("expired"));
});

Deno.test("bridge: body diubah / secret salah / sig rusak → bad_signature", async () => {
  const body = JSON.stringify({ v: 1, action: "close_account", payload: { user_id: "u1" } });
  const sig = await signBridge(SECRET, now, body);
  const tampered = body.replace("u1", "u2");
  await assert.rejects(verifyBridge(await signed(tampered, now, SECRET, sig), SECRET, now), code("bad_signature"));
  await assert.rejects(verifyBridge(await signed(body, now, "other-secret"), SECRET, now), code("bad_signature"));
  await assert.rejects(verifyBridge(await signed(body, now, SECRET, "zz"), SECRET, now), code("bad_signature"));
  // ts ikut ditandatangani: ganti ts dengan sig lama → gagal
  await assert.rejects(verifyBridge(await signed(body, now + 1, SECRET, sig), SECRET, now), code("bad_signature"));
});

Deno.test("bridge: v ≠ 1 ditolak", async () => {
  const body = JSON.stringify({ v: 2, action: "get_batch", payload: {} });
  await assert.rejects(verifyBridge(await signed(body), SECRET, now), code("bad_version"));
});

Deno.test("bridge: callBridge menandatangani body persis yang dikirim; error identity → BridgeError", async () => {
  const m = mockFetch(async (c) => {
    const ts = c.headers.get("x-bridge-ts")!;
    assert.equal(c.headers.get("x-bridge-sig"), await signBridge("core-to-identity", ts, c.body));
    assert.equal(c.url.toString(), "https://identity.test/functions/v1/bridge");
    const { v, action, payload } = JSON.parse(c.body);
    assert.deepEqual([v, action, payload], [1, "check_ids", { user_ids: ["u1"] }]);
    return jsonRes(200, { ok: true, data: { missing: { user_ids: [] } } });
  });
  const target = { url: "https://identity.test/functions/v1/", secret: "core-to-identity", fetch: m.fetch };
  assert.deepEqual(await callBridge(target, "check_ids", { user_ids: ["u1"] }), { missing: { user_ids: [] } });

  const bad = mockFetch(() => jsonRes(404, { ok: false, error: { code: "user_not_found", message: "no user" } }));
  await assert.rejects(
    callBridge({ ...target, fetch: bad.fetch }, "send_email", {}),
    (e) => e instanceof BridgeError && e.permanent && e.code === "user_not_found",
  );
  const down = mockFetch(() => jsonRes(503, { ok: false, error: { code: "unavailable", message: "x" } }));
  await assert.rejects(
    callBridge({ ...target, fetch: down.fetch }, "send_email", {}),
    (e) => e instanceof BridgeError && !e.permanent,
  );
});
