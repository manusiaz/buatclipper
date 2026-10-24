import assert from "node:assert/strict";
import { hmacHex } from "../_shared/http.ts";
import { fakeRpc, jsonRes, mockFetch } from "../_shared/testing.ts";
import { type DueFulfillment, isPublicHttpsUrl, runFulfill, webhookSignature } from "./fulfill.ts";

const NOW = Date.parse("2026-10-19T12:00:00Z");
const row = (over: Partial<DueFulfillment> = {}): DueFulfillment => ({
  id: "f0000000-0000-4000-8000-000000000001",
  user_id: "u1",
  reward_type_id: "rt1",
  amount: 8,
  recipient: { game_user_id: "123456", zone_id: "7890" },
  fulfillment: "webhook",
  webhook_url: "https://brand.example.com/hooks/reward",
  webhook_secret: "whsec_brand",
  attempts: 0,
  ...over,
});

Deno.test("fulfill: tanda tangan webhook t=<ts>,v1=<hex hmac(secret, ts.body)>", async () => {
  const sig = await webhookSignature("whsec_brand", 1790000000, '{"a":1}');
  assert.equal(sig, `t=1790000000,v1=${await hmacHex("whsec_brand", '1790000000.{"a":1}')}`);
  // vektor independen: printf '1790000000.{"a":1}' | openssl dgst -sha256 -hmac whsec_brand
  assert.equal(sig, "t=1790000000,v1=fe606a4446e58ff100594ad058df38cbcabf8f6a78849afccaa6f32d451d60f3");
});

Deno.test("fulfill: webhook terkirim → body non-PII + idempotency_key, hasil ok", async () => {
  const f = fakeRpc({ worker_fulfillments_due: () => [row()], worker_fulfillment_result: () => null });
  const m = mockFetch(async (c) => {
    const [, t, v1] = /^t=(\d+),v1=([0-9a-f]{64})$/.exec(c.headers.get("x-clipper-signature")!)!;
    assert.equal(Number(t), NOW / 1000);
    assert.equal(v1, await hmacHex("whsec_brand", `${t}.${c.body}`));
    assert.deepEqual(JSON.parse(c.body), {
      fulfillment_id: row().id,
      reward_type_id: "rt1",
      amount: 8,
      recipient: { game_user_id: "123456", zone_id: "7890" },
      idempotency_key: row().id,
    });
    return jsonRes(200, { reference: "TOPUP-991" });
  });
  const s = await runFulfill({ rpc: f.rpc, fetch: m.fetch, now: () => NOW });
  assert.deepEqual(f.calls.find((c) => c.fn === "worker_fulfillment_result")!.args, {
    p_fulfillment: row().id,
    p_ok: true,
    p_ref: "TOPUP-991",
    p_error: null,
  });
  assert.equal(s.delivered, 1);
  assert.equal(f.calls[0].args.p_limit, 50);
});

Deno.test("fulfill: webhook 5xx / timeout → gagal (dicoba lagi SQL); URL internal ditolak tanpa request", async () => {
  const f = fakeRpc({
    worker_fulfillments_due:
      () => [row(), row({ id: "f2", webhook_url: "https://169.254.169.254/latest" }), row({ id: "f3" })],
    worker_fulfillment_result: () => null,
  });
  let n = 0;
  const m = mockFetch(() => (n++ === 0 ? jsonRes(502, {}) : Promise.reject(new DOMException("t", "TimeoutError"))));
  const s = await runFulfill({ rpc: f.rpc, fetch: m.fetch, now: () => NOW });
  const results = Object.fromEntries(
    f.calls.filter((c) => c.fn === "worker_fulfillment_result").map((c) => [c.args.p_fulfillment, c.args.p_error]),
  );
  assert.deepEqual(results, { [row().id]: "http_502", f2: "webhook_url_not_allowed", f3: "timeout" });
  assert.equal(m.calls.length, 2);
  assert.equal(s.failed, 3);
});

Deno.test("fulfill: code_pool memasang kode; pool habis = gagal", async () => {
  const f = fakeRpc({
    worker_fulfillments_due:
      () => [row({ id: "c1", fulfillment: "code_pool" }), row({ id: "c2", fulfillment: "code_pool" })],
    worker_assign_code: (a) => (a.p_fulfillment === "c1" ? "MLBB-ABCD-1234" : null),
    worker_fulfillment_result: () => null,
  });
  await runFulfill({ rpc: f.rpc, now: () => NOW });
  const res = f.calls.filter((c) => c.fn === "worker_fulfillment_result").map((c) => c.args);
  // pool habis: SQL worker_assign_code sudah memindah ke on_hold, worker tidak mencatat percobaan gagal lagi
  assert.deepEqual(res, [{ p_fulfillment: "c1", p_ok: true, p_ref: "MLBB-ABCD-1234", p_error: null }]);
});

Deno.test("fulfill: guard SSRF", () => {
  assert.ok(isPublicHttpsUrl("https://brand.example.com/x"));
  for (
    const u of [
      "http://brand.example.com",
      "https://localhost/x",
      "https://10.0.0.5/",
      "https://192.168.1.1",
      "https://[::1]/",
      "https://user:pw@brand.com",
      "https://metadata.internal/",
    ]
  ) {
    assert.equal(isPublicHttpsUrl(u), false, u);
  }
});
