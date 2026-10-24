import assert from "node:assert/strict";
import { signBridge } from "./bridge.ts";
import { busSecret, handleBusDelivery } from "./bus.ts";
import { HttpError } from "./http.ts";

const SECRETS: Record<string, string> = {
  BUS_SECRET_FROM_CREATOR: "creator-to-admin",
  BUS_SECRET_FROM_BRAND: "brand-to-admin",
};
const secret = (from: string) => busSecret(from, (k) => SECRETS[k] ?? "");

async function delivery(
  from: string,
  payload: unknown,
  signWith = SECRETS[`BUS_SECRET_FROM_${from.toUpperCase()}`] ?? "x",
) {
  const body = JSON.stringify({ v: 1, action: "bus.deliver", payload });
  const ts = Math.floor(Date.now() / 1000);
  return new Request("https://admin.test/functions/v1/bridge", {
    method: "POST",
    headers: { "x-bridge-from": from, "x-bridge-ts": String(ts), "x-bridge-sig": await signBridge(signWith, ts, body) },
    body,
  });
}

Deno.test("bus: kiriman sah → api.bus_receive dengan pengirim dari header", async () => {
  const calls: unknown[] = [];
  const events = [{ id: "4f1c0e1e-2f0a-4a51-9b55-0e3f1f8a0001", topic: "submission.created", payload: { a: 1 } }];
  const res = await handleBusDelivery(await delivery("creator", { source: "creator", events }), (fn, args) => {
    calls.push([fn, args]);
    return Promise.resolve({ applied: 1, skipped: 0 } as never);
  }, secret);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, data: { applied: 1, skipped: 0 } });
  assert.deepEqual(calls, [["bus_receive", { p_source: "creator", p_events: events }]]);
});

Deno.test("bus: after dijalankan sesudah bus_receive; after gagal → error (pengirim mengulang batch)", async () => {
  const order: string[] = [];
  const events = [{
    id: "4f1c0e1e-2f0a-4a51-9b55-0e3f1f8a0002",
    topic: "profile.anonymize",
    payload: { user_id: "u1" },
  }];
  const rpc = () => (order.push("rpc"), Promise.resolve({ applied: 1 } as never));
  const res = await handleBusDelivery(await delivery("creator", { source: "creator", events }), rpc, secret, (ev) => {
    order.push(`after:${ev[0].topic}`);
    return Promise.resolve();
  });
  assert.equal(res.status, 200);
  assert.deepEqual(order, ["rpc", "after:profile.anonymize"]);
  await assert.rejects(async () =>
    handleBusDelivery(
      await delivery("creator", { source: "creator", events }),
      rpc,
      secret,
      () => Promise.reject(new Error("storage down")),
    )
  );
});

Deno.test("bus: secret pengirim lain / sumber di body beda header / pengirim tak dikenal ditolak", async () => {
  const rpc = () => Promise.reject(new Error("RPC tidak boleh dipanggil"));
  // brand mengaku creator: tanda tangan dengan secret brand tidak cocok secret creator
  await assert.rejects(
    async () =>
      handleBusDelivery(
        await delivery("creator", { source: "creator", events: [] }, SECRETS.BUS_SECRET_FROM_BRAND),
        rpc,
        secret,
      ),
    (e: unknown) => e instanceof HttpError && e.status === 401,
  );
  await assert.rejects(
    async () => handleBusDelivery(await delivery("brand", { source: "creator", events: [] }), rpc, secret),
    (e: unknown) => e instanceof HttpError && e.status === 400,
  );
  await assert.rejects(
    async () => handleBusDelivery(await delivery("evil", { source: "evil", events: [] }), rpc, secret),
    (e: unknown) => e instanceof HttpError && e.status === 401 && e.code === "bad_source",
  );
});
