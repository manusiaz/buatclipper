import assert from "node:assert/strict";
import { BridgeError } from "../_shared/bridge.ts";
import { hmacHex, HttpError } from "../_shared/http.ts";
import { fakeRpc } from "../_shared/testing.ts";
import { handleUnsubscribe, runNotify, unsubscribeUrl } from "./notify.ts";

const U = "6f1c2d3e-4b5a-4c6d-8e7f-001122334455";
const BASE = "https://core.test/functions/v1/notify/unsubscribe";
const SECRET = "unsub-secret";

function setup(
  notifs: Record<number, unknown>,
  msgs: { msg_id: number; message: { notification_id: number; email?: boolean; push?: boolean } }[],
) {
  let n = 0;
  return fakeRpc({
    worker_dequeue: () => (n++ === 0 ? msgs : []),
    worker_notification: (a) => notifs[a.p_id as number] ?? null,
    worker_ack: () => true,
  });
}

Deno.test("notify: email + push lewat bridge identity; promo membawa unsubscribe_url; ack setelah sukses", async () => {
  const f = setup({
    1: {
      user_id: U,
      event: "submission.approved",
      payload: { submission_id: "s1" },
      promo: false,
      created: 1761300000,
    },
    2: { user_id: U, event: "campaign.new", payload: { campaign_id: "c1" }, promo: true, created: 1761300000 },
  }, [{ msg_id: 10, message: { notification_id: 1 } }, { msg_id: 11, message: { notification_id: 2 } }]);
  const sent: { action: string; payload: Record<string, unknown> }[] = [];
  const s = await runNotify({
    rpc: f.rpc,
    bridge: (action, payload) => {
      sent.push({ action, payload });
      return Promise.resolve({ ok: true });
    },
    unsubscribeSecret: SECRET,
    unsubscribeBase: BASE,
  });
  const emails = sent.filter((x) => x.action === "send_email");
  assert.equal(emails.length, 2);
  const promo = emails.find((e) => e.payload.event === "campaign.new")!.payload;
  assert.equal(promo.unsubscribe_url, `${BASE}?u=${U}&s=${await hmacHex(SECRET, U)}`);
  assert.equal(emails.find((e) => e.payload.event === "submission.approved")!.payload.unsubscribe_url, undefined);
  assert.deepEqual(sent.filter((x) => x.action === "send_push").map((x) => Object.keys(x.payload).sort()), [[
    "event",
    "notification_id",
    "payload",
    "user_id",
  ], ["event", "notification_id", "payload", "user_id"]]);
  assert.ok(
    emails.every((e) => typeof e.payload.notification_id === "number"),
    "notification_id ikut untuk Idempotency-Key",
  );
  assert.ok(
    emails.every((e) => e.payload.notification_created === 1761300000),
    "O7-C1: waktu dibuat ikut Idempotency-Key",
  );
  assert.deepEqual(f.calls.filter((c) => c.fn === "worker_ack").map((c) => c.args), [
    { p_queue: "email", p_msg_id: 10 },
    { p_queue: "email", p_msg_id: 11 },
  ]);
  assert.equal(s.sent, 2);
});

Deno.test("notify: kanal per pesan — email saja / push saja (broadcast A6.1, email promosi dimatikan)", async () => {
  const f = setup({
    1: { user_id: U, event: "broadcast.sent", payload: {}, promo: true },
    2: { user_id: U, event: "broadcast.sent", payload: {}, promo: true },
  }, [
    { msg_id: 10, message: { notification_id: 1, email: true, push: false } },
    { msg_id: 11, message: { notification_id: 2, email: false, push: true } },
  ]);
  const sent: { action: string; payload: Record<string, unknown> }[] = [];
  const s = await runNotify({
    rpc: f.rpc,
    bridge: (action, payload) => {
      sent.push({ action, payload });
      return Promise.resolve({ ok: true });
    },
    unsubscribeSecret: SECRET,
    unsubscribeBase: BASE,
  });
  assert.deepEqual(sent.map((x) => `${x.action}:${x.payload.notification_id}`).sort(), ["send_email:1", "send_push:2"]);
  assert.deepEqual([s.sent, s.pushed, s.dropped], [1, 1, 0]);
});

Deno.test("notify: identity 5xx → tidak di-ack; 4xx permanen → di-ack (tidak diulang)", async () => {
  const f = setup({
    1: { user_id: U, event: "e", payload: {}, promo: false },
    2: { user_id: U, event: "e", payload: {}, promo: false },
  }, [
    { msg_id: 1, message: { notification_id: 1 } },
    { msg_id: 2, message: { notification_id: 2 } },
  ]);
  let call = 0;
  const s = await runNotify({
    rpc: f.rpc,
    bridge: (action) => {
      if (action === "send_push") return Promise.resolve(null);
      return Promise.reject(
        call++ === 0 ? new BridgeError(503, "unavailable", "down") : new BridgeError(404, "user_not_found", "gone"),
      );
    },
    unsubscribeSecret: SECRET,
    unsubscribeBase: BASE,
  });
  assert.deepEqual(f.calls.filter((c) => c.fn === "worker_ack").map((c) => c.args.p_msg_id), [2]);
  assert.deepEqual([s.retried, s.dropped], [1, 1]);
});

Deno.test("notify: unsubscribe one-click (POST) & GET dengan HMAC; tanda tangan salah 403", async () => {
  const f = fakeRpc({ worker_unsubscribe: () => null });
  const url = await unsubscribeUrl(BASE, SECRET, U);
  const post = await handleUnsubscribe(new Request(url, { method: "POST", body: "List-Unsubscribe=One-Click" }), {
    rpc: f.rpc,
    unsubscribeSecret: SECRET,
  });
  assert.equal(post.status, 200);
  const get = await handleUnsubscribe(new Request(url), { rpc: f.rpc, unsubscribeSecret: SECRET });
  assert.equal(get.status, 200);
  assert.match(get.headers.get("content-type")!, /^text\/plain/);
  assert.deepEqual(f.calls.map((c) => c.args), [{ p_user: U }, { p_user: U }]);
  const forged = url.replace(/s=[0-9a-f]+/, `s=${await hmacHex("other", U)}`);
  await assert.rejects(
    handleUnsubscribe(new Request(forged), { rpc: f.rpc, unsubscribeSecret: SECRET }),
    (e) => e instanceof HttpError && e.status === 403,
  );
  const otherUser = url.replace(U, "6f1c2d3e-4b5a-4c6d-8e7f-001122334456");
  await assert.rejects(
    handleUnsubscribe(new Request(otherUser), { rpc: f.rpc, unsubscribeSecret: SECRET }),
    (e) => e instanceof HttpError && e.status === 403,
  );
  assert.equal(f.calls.length, 2);
});
