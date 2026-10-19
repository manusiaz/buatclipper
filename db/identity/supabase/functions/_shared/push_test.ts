import { assertEquals } from "@std/assert";
import { type PushSender, sendPushToUser } from "./push.ts";
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
