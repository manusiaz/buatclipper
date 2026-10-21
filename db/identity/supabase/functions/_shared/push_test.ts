import { assertEquals, assertRejects } from "@std/assert";
import {
  type ExpoMessage,
  expoMessage,
  type ExpoReceipt,
  expoReceipts,
  expoSend,
  type PushSender,
  resolveExpoReceipts,
  sendPushToUser,
} from "./push.ts";
import { FakeRpc } from "./testing.ts";

Deno.test("web push: 404/410 endpoints are deleted, others counted, delivered ones touched", async () => {
  const subs = [
    { endpoint: "https://push.test/ok", p256dh: "k1", auth_secret: "a1" },
    { endpoint: "https://push.test/gone", p256dh: "k2", auth_secret: "a2" },
    { endpoint: "https://push.test/notfound", p256dh: "k3", auth_secret: "a3" },
    { endpoint: "https://push.test/busy", p256dh: "k4", auth_secret: "a4" },
  ];
  const rpc = new FakeRpc({
    svc_push_subscriptions: () => subs,
    svc_delete_push: () => null,
    svc_touch_push: () => null,
  });
  const payloads: string[] = [];
  const sender: PushSender = {
    send(sub, payload) {
      payloads.push(payload);
      const status = {
        "https://push.test/gone": 410,
        "https://push.test/notfound": 404,
        "https://push.test/busy": 503,
      }[sub.endpoint];
      return status ? Promise.reject(Object.assign(new Error("push"), { statusCode: status })) : Promise.resolve();
    },
  };
  const res = await sendPushToUser({ rpc, sender }, "00000000-0000-0000-0000-0000000000a1", {
    title: "Payout Rp150.000 berhasil",
    body: "Dana sudah ditransfer.",
    url: "https://app.clipper.test/wallet",
    event: "payout.paid",
  });
  assertEquals(res, { sent: 1, removed: 2, failed: 1 });
  assertEquals(rpc.named("svc_delete_push").map((c) => c.args.p_endpoint).sort(), [
    "https://push.test/gone",
    "https://push.test/notfound",
  ]);
  assertEquals(rpc.named("svc_touch_push").map((c) => c.args.p_endpoint), ["https://push.test/ok"]);
  assertEquals(rpc.named("svc_push_subscriptions")[0].args, { p_user: "00000000-0000-0000-0000-0000000000a1" });
  assertEquals(JSON.parse(payloads[0]).url, "https://app.clipper.test/wallet");
});

Deno.test("web push: user without subscriptions → nothing sent", async () => {
  const rpc = new FakeRpc({ svc_push_subscriptions: () => [] });
  const res = await sendPushToUser({ rpc, sender: { send: () => Promise.resolve() } }, "u", {
    title: "t",
    body: "b",
    url: "u",
    event: "e",
  });
  assertEquals(res, { sent: 0, removed: 0, failed: 0 });
});

Deno.test("web-push module runs under Deno: VAPID JWT + aes128gcm payload encryption (no network)", async () => {
  const { default: webpush } = await import("web-push");
  const { createECDH, randomBytes } = await import("node:crypto");
  const vapid = webpush.generateVAPIDKeys();
  const ua = createECDH("prime256v1");
  ua.generateKeys();
  const sub = {
    endpoint: "https://fcm.googleapis.com/fcm/send/abc",
    keys: { p256dh: ua.getPublicKey("base64url"), auth: randomBytes(16).toString("base64url") },
  };
  const details = webpush.generateRequestDetails(sub, JSON.stringify({ title: "t" }), {
    vapidDetails: { subject: "mailto:ops@clipper.test", publicKey: vapid.publicKey, privateKey: vapid.privateKey },
    TTL: 60,
  });
  assertEquals(details.method, "POST");
  assertEquals(details.endpoint, sub.endpoint);
  assertEquals(details.headers["Content-Encoding"], "aes128gcm");
  assertEquals(String(details.headers.Authorization).startsWith("vapid t="), true);
  assertEquals((details.body as Uint8Array).length > 0, true);
});

Deno.test("expo push (app native): one batch, DeviceNotRegistered deleted, ok touched, web push still per endpoint", async () => {
  const subs = [
    { kind: "webpush" as const, endpoint: "https://push.test/ok", p256dh: "k1", auth_secret: "a1" },
    { kind: "expo" as const, endpoint: "ExponentPushToken[okokokokokokokok]", p256dh: null, auth_secret: null },
    { kind: "expo" as const, endpoint: "ExponentPushToken[gonegonegonegone]", p256dh: null, auth_secret: null },
    { kind: "expo" as const, endpoint: "ExponentPushToken[busybusybusybusy]", p256dh: null, auth_secret: null },
  ];
  const rpc = new FakeRpc({
    svc_push_subscriptions: () => subs,
    svc_delete_push: () => null,
    svc_touch_push: () => null,
    svc_add_push_tickets: () => null,
  });
  const batches: ExpoMessage[][] = [];
  const web: string[] = [];
  const sender: PushSender = {
    send: (sub) => (web.push(sub.endpoint), Promise.resolve()),
    sendExpo: (messages) => {
      batches.push(messages);
      return Promise.resolve([
        { status: "ok", id: "t1" },
        { status: "error", message: "not registered", details: { error: "DeviceNotRegistered" } },
        { status: "error", message: "rate", details: { error: "MessageRateExceeded" } },
      ]);
    },
  };
  const res = await sendPushToUser({ rpc, sender }, "u1", {
    title: "Submisi kamu disetujui",
    body: "Views-nya sekarang dihitung.",
    url: "https://app.clipper.test/tasks",
    event: "submission.approved",
    actions: [
      { action: "wallet", title: "Lihat saldo", url: "https://app.clipper.test/wallet" },
      { action: "campaign", title: "Kirim clip lagi", url: "https://app.clipper.test/campaigns/c1" },
    ],
  });
  assertEquals(res, { sent: 2, removed: 1, failed: 1 });
  assertEquals(web, ["https://push.test/ok"]);
  assertEquals(batches.length, 1);
  assertEquals(batches[0].map((m) => m.to), subs.slice(1).map((s) => s.endpoint));
  assertEquals(batches[0][0].categoryId, "submission_approved");
  assertEquals(batches[0][0].data, {
    url: "https://app.clipper.test/tasks",
    event: "submission.approved",
    actions: { wallet: "https://app.clipper.test/wallet", campaign: "https://app.clipper.test/campaigns/c1" },
  });
  assertEquals(rpc.named("svc_delete_push").map((c) => c.args.p_endpoint), ["ExponentPushToken[gonegonegonegone]"]);
  assertEquals(rpc.named("svc_touch_push").map((c) => c.args.p_endpoint).sort(), [
    "ExponentPushToken[okokokokokokokok]",
    "https://push.test/ok",
  ]);
  assertEquals(rpc.named("svc_add_push_tickets").map((c) => c.args), [
    { p_endpoints: ["ExponentPushToken[okokokokokokokok]"], p_tickets: ["t1"] },
  ]);
});

Deno.test("expo push: accepted tickets recorded in one svc_add_push_tickets call, no receipt lookup before sending", async () => {
  const subs = [
    { kind: "expo" as const, endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]", p256dh: null, auth_secret: null },
    { kind: "expo" as const, endpoint: "ExponentPushToken[bbbbbbbbbbbbbbbb]", p256dh: null, auth_secret: null },
    { kind: "expo" as const, endpoint: "ExponentPushToken[cccccccccccccccc]", p256dh: null, auth_secret: null },
  ];
  const rpc = new FakeRpc({
    svc_push_subscriptions: () => subs,
    svc_touch_push: () => null,
    svc_add_push_tickets: () => null,
  });
  const res = await sendPushToUser(
    {
      rpc,
      sender: {
        send: () => Promise.reject(new Error("web push not expected")),
        sendExpo: () =>
          Promise.resolve([
            { status: "ok" as const, id: "tk-a" },
            { status: "ok" as const }, // tanpa id: tidak ada receipt yang bisa dicek
            { status: "ok" as const, id: "tk-c" },
          ]),
      },
    },
    "u1",
    { title: "t", body: "b", url: "https://app.clipper.test/tasks", event: "submission.approved" },
  );
  assertEquals(res, { sent: 3, removed: 0, failed: 0 });
  assertEquals(rpc.calls.map((c) => c.fn).filter((f) => f !== "svc_touch_push"), [
    "svc_push_subscriptions",
    "svc_add_push_tickets",
  ]);
  assertEquals(rpc.named("svc_add_push_tickets")[0].args, {
    p_endpoints: ["ExponentPushToken[aaaaaaaaaaaaaaaa]", "ExponentPushToken[cccccccccccccccc]"],
    p_tickets: ["tk-a", "tk-c"],
  });
  assertEquals(rpc.named("svc_touch_push").map((c) => Object.keys(c.args)), [["p_endpoint"], ["p_endpoint"], [
    "p_endpoint",
  ]]);
});

Deno.test("expo push: recording tickets fails → push still counted sent", async () => {
  const rpc = new FakeRpc({
    svc_push_subscriptions:
      () => [{ kind: "expo", endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]", p256dh: null, auth_secret: null }],
    svc_touch_push: () => null,
    svc_add_push_tickets: () => {
      throw new Error("db down");
    },
  });
  const res = await sendPushToUser(
    {
      rpc,
      sender: { send: () => Promise.resolve(), sendExpo: () => Promise.resolve([{ status: "ok", id: "x" }]) },
    },
    "u",
    { title: "t", body: "b", url: "u", event: "payout.paid" },
  );
  assertEquals(res, { sent: 1, removed: 0, failed: 0 });
});

Deno.test("sendPushToUser ignores Live Activity tokens (apns_start / apns_activity): sent by apns.ts only", async () => {
  const rpc = new FakeRpc({
    svc_push_subscriptions: () => [
      { kind: "apns_start", endpoint: "ab".repeat(32), p256dh: null, auth_secret: null, activity_ref: null },
      { kind: "apns_activity", endpoint: "cd".repeat(32), p256dh: null, auth_secret: null, activity_ref: "p1" },
      { kind: "webpush", endpoint: "https://push.test/ok", p256dh: "k", auth_secret: "a", activity_ref: null },
    ],
    svc_touch_push: () => null,
  });
  const web: string[] = [];
  const res = await sendPushToUser(
    {
      rpc,
      sender: {
        send: (sub) => (web.push(sub.endpoint), Promise.resolve()),
        sendExpo: () => Promise.reject(new Error("expo not expected")),
      },
    },
    "u",
    { title: "t", body: "b", url: "u", event: "payout.paid" },
  );
  assertEquals(web, ["https://push.test/ok"]);
  assertEquals(res, { sent: 1, removed: 0, failed: 0 });
  assertEquals(rpc.named("svc_touch_push").map((c) => c.args.p_endpoint), ["https://push.test/ok"]);
});

function receiptRpc(due: { ticket: string; endpoint: string }[][]) {
  let round = 0;
  return new FakeRpc({
    svc_due_push_tickets: () => due[round++] ?? [],
    svc_resolve_push_tickets: (a) => ({
      resolved: (a.p_tickets as string[]).length,
      removed: (a.p_dead_endpoints as string[]).length,
      expired: 0,
    }),
  });
}

Deno.test("resolveExpoReceipts: DeviceNotRegistered → dead endpoint, ready receipts resolved, missing ones kept", async () => {
  const rpc = receiptRpc([[
    { ticket: "t-ok", endpoint: "ExponentPushToken[okokokokokokokok]" },
    { ticket: "t-gone", endpoint: "ExponentPushToken[gonegonegonegone]" },
    { ticket: "t-gone-2", endpoint: "ExponentPushToken[gonegonegonegone]" },
    { ticket: "t-rate", endpoint: "ExponentPushToken[busybusybusybusy]" },
    { ticket: "t-wait", endpoint: "ExponentPushToken[waitwaitwaitwait]" },
  ]]);
  const asked: string[][] = [];
  const receipts: Record<string, ExpoReceipt> = {
    "t-ok": { status: "ok" },
    "t-gone": { status: "error", details: { error: "DeviceNotRegistered" } },
    "t-gone-2": { status: "error", details: { error: "DeviceNotRegistered" } },
    "t-rate": { status: "error", details: { error: "MessageRateExceeded" } },
  };
  const res = await resolveExpoReceipts({ rpc, receipts: (ids) => (asked.push(ids), Promise.resolve(receipts)) });
  assertEquals(asked, [["t-ok", "t-gone", "t-gone-2", "t-rate", "t-wait"]]);
  assertEquals(rpc.named("svc_due_push_tickets")[0].args, { p_limit: 1000 });
  assertEquals(rpc.named("svc_resolve_push_tickets").map((c) => c.args), [{
    p_tickets: ["t-ok", "t-gone", "t-gone-2", "t-rate"],
    p_dead_endpoints: ["ExponentPushToken[gonegonegonegone]"],
  }]);
  assertEquals(res, { checked: 5, resolved: 4, removed: 1, expired: 0 });
});

Deno.test("resolveExpoReceipts: full batches loop until the queue drains, capped by rounds; no tickets → no Expo call", async () => {
  const t = (n: string) => ({ ticket: n, endpoint: `ExponentPushToken[${n.padEnd(16, "x")}]` });
  const ok = (ids: string[]) => Promise.resolve(Object.fromEntries(ids.map((id) => [id, { status: "ok" as const }])));
  const rpc = receiptRpc([[t("a"), t("b")], [t("c"), t("d")], [t("e")]]);
  const res = await resolveExpoReceipts({ rpc, receipts: ok }, { batch: 2 });
  assertEquals(rpc.named("svc_due_push_tickets").length, 3);
  assertEquals(res, { checked: 5, resolved: 5, removed: 0, expired: 0 });

  const capped = receiptRpc([[t("a"), t("b")], [t("c"), t("d")], [t("e"), t("f")]]);
  assertEquals((await resolveExpoReceipts({ rpc: capped, receipts: ok }, { batch: 2, rounds: 2 })).checked, 4);

  let called = false;
  const empty = receiptRpc([]);
  assertEquals(
    await resolveExpoReceipts({ rpc: empty, receipts: () => (called = true, Promise.resolve({})) }),
    { checked: 0, resolved: 0, removed: 0, expired: 0 },
  );
  assertEquals([called, empty.named("svc_resolve_push_tickets").length], [false, 0]);
});

Deno.test("resolveExpoReceipts: no receipt ready in a full batch → stop (no busy loop); Expo down → rejects, nothing deleted", async () => {
  const t = (n: string) => ({ ticket: n, endpoint: `ExponentPushToken[${n.padEnd(16, "x")}]` });
  const rpc = receiptRpc([[t("a"), t("b")], [t("a"), t("b")]]);
  const res = await resolveExpoReceipts({ rpc, receipts: () => Promise.resolve({}) }, { batch: 2 });
  assertEquals(rpc.named("svc_due_push_tickets").length, 1);
  assertEquals(rpc.named("svc_resolve_push_tickets")[0].args, { p_tickets: [], p_dead_endpoints: [] });
  assertEquals(res.checked, 2);
  const down = receiptRpc([[t("a")]]);
  await assertRejects(() => resolveExpoReceipts({ rpc: down, receipts: () => Promise.reject(new Error("503")) }));
  assertEquals(down.named("svc_resolve_push_tickets").length, 0);
});

Deno.test("expoReceipts: getReceipts in chunks of 1000 ids, merged by ticket id", async () => {
  const bodies: { ids: string[] }[] = [];
  const ids = Array.from({ length: 1001 }, (_, i) => `t${i}`);
  const out = await expoReceipts(ids, (_url, init) => {
    const body = JSON.parse(String(init?.body)) as { ids: string[] };
    bodies.push(body);
    return Promise.resolve(Response.json({ data: { [body.ids[0]]: { status: "ok" } } }));
  }, undefined);
  assertEquals(bodies.map((b) => b.ids.length), [1000, 1]);
  assertEquals(Object.keys(out).sort(), ["t0", "t1000"]);
});

Deno.test("expo push: Expo API down → tokens counted failed, nothing deleted", async () => {
  const rpc = new FakeRpc({
    svc_push_subscriptions:
      () => [{ kind: "expo", endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]", p256dh: null, auth_secret: null }],
  });
  const res = await sendPushToUser(
    {
      rpc,
      sender: { send: () => Promise.resolve(), sendExpo: () => Promise.reject(new Error("503")) },
    },
    "u",
    {
      title: "t",
      body: "b",
      url: "https://app.clipper.test/wallet",
      event: "payout.paid",
    },
  );
  assertEquals(res, { sent: 0, removed: 0, failed: 1 });
  assertEquals(rpc.named("svc_delete_push").length, 0);
});

Deno.test("expoSend: POST exp.host in chunks of 100, bearer token when set, HTTP error rejects", async () => {
  const calls: { url: string; body: unknown[]; auth: string | null }[] = [];
  const fake = ((url: string, init: RequestInit) => {
    const body = JSON.parse(String(init.body)) as unknown[];
    calls.push({ url, body, auth: new Headers(init.headers).get("authorization") });
    return Promise.resolve(Response.json({ data: body.map(() => ({ status: "ok" })) }));
  }) as unknown as typeof fetch;
  const msgs = Array.from(
    { length: 150 },
    (_, i) =>
      expoMessage(`ExponentPushToken[${String(i).padStart(16, "x")}]`, {
        title: "t",
        body: "b",
        url: "u",
        event: "payout.paid",
      }),
  );
  const tickets = await expoSend(msgs, fake, "tok");
  assertEquals(tickets.length, 150);
  assertEquals(calls.map((c) => c.body.length), [100, 50]);
  assertEquals(calls[0].url, "https://exp.host/--/api/v2/push/send");
  assertEquals(calls[0].auth, "Bearer tok");
  assertEquals(msgs[0].categoryId, undefined);
  const down = (() => Promise.resolve(new Response("x", { status: 500 }))) as unknown as typeof fetch;
  await assertRejects(() => expoSend(msgs.slice(0, 1), down, undefined));
});
