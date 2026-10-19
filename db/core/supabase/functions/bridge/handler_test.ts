import assert from "node:assert/strict";
import { signBridge } from "../_shared/bridge.ts";
import { RpcError } from "../_shared/db.ts";
import { HttpError } from "../_shared/http.ts";
import { fakeRpc } from "../_shared/testing.ts";
import { type BridgeDeps, createBridgeHandler, INBOUND, reconcileIds } from "./handler.ts";

const SECRET = "identity-to-core";

function handler(
  rpcHandlers: Record<string, (a: Record<string, unknown>) => unknown>,
  identity: BridgeDeps["identity"] = () => Promise.resolve(null),
) {
  const f = fakeRpc(rpcHandlers);
  const h = createBridgeHandler({
    rpc: f.rpc,
    inboundSecret: () => SECRET,
    requireApiKey: (req) =>
      req.headers.get("apikey") === "sb_secret_core"
        ? Promise.resolve()
        : Promise.reject(new HttpError(401, "unauthorized")),
    identity,
    background: async (task) => ({ result: await task, accepted: false }),
  });
  return { h, calls: f.calls };
}

async function inbound(action: string, payload: Record<string, unknown>, secret = SECRET) {
  const body = JSON.stringify({ v: 1, action, payload });
  const ts = Math.floor(Date.now() / 1000);
  return new Request("https://core.test/functions/v1/bridge", {
    method: "POST",
    headers: { "x-bridge-ts": String(ts), "x-bridge-sig": await signBridge(secret, ts, body) },
    body,
  });
}

Deno.test("bridge: aksi identity → RPC bridge_* 1:1", async () => {
  const { h, calls } = handler({
    bridge_get_batch: () => ({ id: "b1", payouts: [] }),
    bridge_mark_instant: () => null,
    bridge_close_account: () => ({ ok: false, reason: "pending_balance" }),
  });
  let r = await h(await inbound("get_batch", { batch_id: "b1" }));
  assert.deepEqual(await r.json(), { ok: true, data: { id: "b1", payouts: [] } });
  r = await h(await inbound("mark_instant", { payout_id: "p1", status: "paid", provider_ref: "DISB-1" }));
  assert.equal(r.status, 200);
  r = await h(await inbound("close_account", { user_id: "u1" }));
  assert.deepEqual(await r.json(), { ok: true, data: { ok: false, reason: "pending_balance" } });
  assert.deepEqual(calls.map((c) => [c.fn, c.args]), [
    ["bridge_get_batch", { p_batch: "b1" }],
    ["bridge_mark_instant", { p_payout: "p1", p_status: "paid", p_provider_ref: "DISB-1", p_error: null }],
    ["bridge_close_account", { p_user: "u1" }],
  ]);
  assert.deepEqual(Object.keys(INBOUND).sort(), [
    "attach_export",
    "attach_proof",
    "close_account",
    "fulfillment_export",
    "get_batch",
    "get_payout",
    "mark_instant",
    "pph21",
    "raise_fraud_flag",
  ]);
});

Deno.test("bridge: HMAC salah / aksi tak dikenal / payload kurang / error RPC → {ok:false,error}", async () => {
  const { h, calls } = handler({
    bridge_get_payout: () => {
      throw new RpcError("bridge_get_payout", "P0002", "payout tidak ada");
    },
  });
  let r = await h(await inbound("get_batch", { batch_id: "b1" }, "wrong"));
  assert.deepEqual([r.status, (await r.json()).error.code], [401, "bad_signature"]);
  r = await h(await inbound("drop_tables", {}));
  assert.deepEqual([r.status, (await r.json()).error.code], [400, "unknown_action"]);
  r = await h(await inbound("reconcile_ids", {})); // aksi cron tidak bisa dipanggil lewat HMAC
  assert.equal(r.status, 400);
  r = await h(await inbound("attach_proof", { target: "payout", id: "x", proof_ref: "r" }));
  assert.deepEqual([r.status, (await r.json()).error.code], [400, "bad_payload"]);
  r = await h(await inbound("get_payout", { payout_id: "p404" }));
  assert.deepEqual([r.status, (await r.json()).ok], [404, false]);
  assert.equal(calls.length, 1);
});

Deno.test("bridge: cron apikey → disburse/ban_user diteruskan ke identity; tanpa apikey 401", async () => {
  const sent: [string, Record<string, unknown>][] = [];
  const { h } = handler({}, (a, p) => {
    sent.push([a, p]);
    return Promise.resolve({ ok: true });
  });
  const cron = (body: unknown, key = "sb_secret_core") =>
    new Request("https://core.test/functions/v1/bridge", {
      method: "POST",
      headers: { apikey: key },
      body: JSON.stringify(body),
    });
  assert.equal((await h(cron({ action: "disburse", payout_id: "p1" }))).status, 200);
  assert.equal((await h(cron({ action: "ban_user", payload: { user_id: "u1" } }))).status, 200);
  assert.equal((await h(cron({ action: "ban_user", user_id: "u2", unban: true }))).status, 200);
  assert.equal((await h(cron({ action: "disburse", payout_id: "p1" }, "wrong"))).status, 401);
  assert.equal((await h(cron({ action: "get_batch", batch_id: "b" }))).status, 400); // aksi identity tidak bisa lewat apikey
  assert.deepEqual(sent, [
    ["disburse", { payout_id: "p1" }],
    ["ban_user", { user_id: "u1", duration: "876000h" }],
    ["ban_user", { user_id: "u2", duration: "none" }],
  ]);
});

Deno.test("bridge: reconcile_ids → check_ids (dipecah per 1000) → bridge_report_orphans", async () => {
  const users = Array.from({ length: 2500 }, (_, i) => `u${i}`);
  const f = fakeRpc({
    bridge_collect_ids: () => ({ user_ids: users, method_ids: ["m1"], recipient_refs: [] }),
    bridge_report_orphans: () => null,
  });
  const batches: number[] = [];
  const out = await reconcileIds({
    rpc: f.rpc,
    identity: (action, p) => {
      assert.equal(action, "check_ids");
      batches.push((p.user_ids as string[]).length);
      return Promise.resolve({
        missing: {
          user_ids: (p.user_ids as string[]).filter((u) => u === "u7" || u === "u2400"),
          method_ids: p.method_ids as string[],
          recipient_refs: [],
        },
      });
    },
  });
  assert.deepEqual(batches, [1000, 1000, 500]);
  assert.deepEqual(f.calls.find((c) => c.fn === "bridge_report_orphans")!.args, {
    p_missing: { user_ids: ["u7", "u2400"], method_ids: ["m1"], recipient_refs: [] },
  });
  assert.deepEqual(out.missing, { user_ids: 2, method_ids: 1, recipient_refs: 0 });
});
