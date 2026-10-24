import { assert, assertEquals } from "@std/assert";
import { signBridge } from "../_shared/bridge.ts";
import { resendSender } from "../_shared/email.ts";
import { FakeAuthAdmin, FakeCore, FakeRpc, json, post, testCrypto } from "../_shared/testing.ts";
import { type BridgeDeps, createBridgeHandler } from "./handler.ts";

const SECRET = "core-to-identity";
const USER = "00000000-0000-0000-0000-0000000000a1";
const LINKS = {
  app: "https://app.clipper.test",
  brand: "https://brand.clipper.test",
  accounts: "https://accounts.clipper.test",
  admin: "https://admin.clipper.test",
};

function setup(over: Partial<BridgeDeps> = {}) {
  const emails: { url: string; headers: Headers; body: Record<string, unknown> }[] = [];
  const fetchFn = ((url: string, init: RequestInit) => {
    emails.push({ url, headers: new Headers(init.headers), body: JSON.parse(String(init.body)) });
    return Promise.resolve(Response.json({ id: "re_123" }));
  }) as unknown as typeof fetch;
  const rpc = new FakeRpc({
    svc_check_ids: (a) => ({ user_ids: a.p_user_ids, method_ids: [], recipient_refs: [] }),
    svc_platform_roles: (a) => (a.p_user === "00000000-0000-0000-0000-0000000000ad" ? ["admin_super"] : []),
    svc_audit: () => null,
    svc_admin_ids: (a) =>
      ["admin_finance", "admin_ops"].some((r) => (a.p_roles as string[]).includes(r))
        ? [USER, "00000000-0000-0000-0000-0000000000ad"]
        : [],
    shared_device_groups: () => [
      {
        ip: "203.0.113.7",
        user_agent: "Mozilla/5.0 X",
        user_ids: [USER, "00000000-0000-0000-0000-0000000000b1", "00000000-0000-0000-0000-0000000000c1"],
      },
    ],
  });
  const core = new FakeCore({
    raise_fraud_flag: () => ({ id: "f1" }),
    fraud_device_params: () => ({ window_hours: 6, min_accounts: 4 }),
  });
  const authAdmin = new FakeAuthAdmin();
  authAdmin.users.set(USER, { id: USER, email: "andi@contoh.id" });
  const deps: BridgeDeps = {
    secret: () => SECRET,
    rpc,
    core: () => core,
    authAdmin,
    crypto: () => testCrypto(),
    email: () => resendSender({ apiKey: "re_key", from: "Clipper <no-reply@notif.clipper.test>", fetchFn }),
    push: () => Promise.resolve({ send: () => Promise.resolve() }),
    provider: () => {
      throw new Error("not used");
    },
    links: () => LINKS,
    isCron: (req) => req.headers.get("apikey") === "sb_secret_test",
    ...over,
  };
  return { rpc, core, authAdmin, emails, handler: createBridgeHandler(deps) };
}

async function signed(
  action: string,
  payload: Record<string, unknown>,
  opts: { secret?: string; tsOffset?: number } = {},
) {
  const raw = JSON.stringify({ v: 1, action, payload });
  const ts = String(Math.floor(Date.now() / 1000) + (opts.tsOffset ?? 0));
  return post(raw, { "x-bridge-ts": ts, "x-bridge-sig": await signBridge(opts.secret ?? SECRET, ts, raw) });
}

Deno.test("bridge send_email: Resend call with recipient from Auth, escaped template, idempotency key", async () => {
  const s = setup();
  const res = await json(
    await s.handler(
      await signed("send_email", {
        user_id: USER,
        event: "payout.paid",
        payload: { amount: "150000.00" },
        promo: false,
      }),
    ),
  );
  assertEquals(res.body, { ok: true, data: { sent: true, id: "re_123" } });
  const e = s.emails[0];
  assertEquals(e.url, "https://api.resend.com/emails");
  assertEquals(e.headers.get("authorization"), "Bearer re_key");
  assert(/^notif-[0-9a-f]{64}$/.test(e.headers.get("idempotency-key")!));
  assertEquals(e.body.to, ["andi@contoh.id"]);
  assertEquals(e.body.from, "Clipper <no-reply@notif.clipper.test>");
  assertEquals(e.body.subject, "Payout Rp150.000 berhasil");
  assertEquals(e.body.headers, undefined);
});

Deno.test("bridge send_email: notification_id → Idempotency-Key notif-<id>; invalid id refused", async () => {
  const s = setup();
  await s.handler(
    await signed("send_email", { user_id: USER, event: "kyc.approved", payload: {}, notification_id: 4211 }),
  );
  assertEquals(s.emails[0].headers.get("Idempotency-Key"), "notif-4211");
  await s.handler(
    await signed("send_email", {
      user_id: USER,
      event: "kyc.approved",
      payload: {},
      notification_id: "9007199254740993",
    }),
  );
  assertEquals(s.emails[1].headers.get("Idempotency-Key"), "notif-9007199254740993");
  const bad = await json(
    await s.handler(
      await signed("send_email", { user_id: USER, event: "kyc.approved", payload: {}, notification_id: -1 }),
    ),
  );
  assertEquals([bad.status, bad.body.error.code], [400, "invalid_input"]);
  assertEquals(s.emails.length, 2);
});

Deno.test("bridge send_email: promo needs one-click unsubscribe headers", async () => {
  const s = setup();
  const missing = await json(
    await s.handler(await signed("send_email", { user_id: USER, event: "campaign.new", payload: {}, promo: true })),
  );
  assertEquals([missing.status, missing.body.error.code], [400, "unsubscribe_required"]);
  await s.handler(
    await signed("send_email", {
      user_id: USER,
      event: "broadcast.sent",
      payload: { title: "Halo", body: "Isi" },
      promo: true,
      unsubscribe_url: "https://core.clipper.test/functions/v1/notify/unsubscribe?t=abc",
    }),
  );
  assertEquals(s.emails[0].body.headers, {
    "List-Unsubscribe": "<https://core.clipper.test/functions/v1/notify/unsubscribe?t=abc>",
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  });
  const none = await json(
    await s.handler(
      await signed("send_email", {
        user_id: "00000000-0000-0000-0000-0000000000ff",
        event: "kyc.approved",
        payload: {},
      }),
    ),
  );
  assertEquals(none.body.data, { sent: false, reason: "no_email" });
  const unknown = await json(await s.handler(await signed("send_email", { user_id: USER, event: "x.y", payload: {} })));
  assertEquals(unknown.body.error.code, "unknown_event");
});

Deno.test("bridge auth: bad signature, stale timestamp, no credentials, cron key cannot call HMAC actions", async () => {
  const s = setup();
  assertEquals((await json(await s.handler(await signed("check_ids", {}, { secret: "wrong" })))).status, 401);
  assertEquals(
    (await json(await s.handler(await signed("check_ids", {}, { tsOffset: -301 })))).body.error.code,
    "stale_request",
  );
  assertEquals((await json(await s.handler(post({ v: 1, action: "check_ids", payload: {} })))).status, 401);
  const cronHmacAction = await json(await s.handler(post({ action: "check_ids" }, { apikey: "sb_secret_test" })));
  assertEquals(cronHmacAction.body.error.code, "unknown_action");
  assertEquals(s.rpc.named("svc_check_ids").length, 0);
});

Deno.test("bridge check_ids: forwards lists to svc_check_ids", async () => {
  const s = setup();
  const res = await json(
    await s.handler(await signed("check_ids", { user_ids: [USER], method_ids: [], recipient_refs: [] })),
  );
  assertEquals(res.body.data, { missing: { user_ids: [USER], method_ids: [], recipient_refs: [] } });
  assertEquals(
    (await json(await s.handler(await signed("check_ids", { user_ids: ["nope"] })))).body.error.code,
    "invalid_input",
  );
});

Deno.test("bridge ban_user from core: bans clipper, refuses admin target", async () => {
  const s = setup();
  assertEquals(
    (await json(await s.handler(await signed("ban_user", { user_id: USER, duration: "720h" })))).status,
    200,
  );
  assertEquals(s.authAdmin.bans, [{ id: USER, duration: "720h" }]);
  assertEquals(s.rpc.named("svc_audit")[0].args.p_actor, null);
  const admin = await json(
    await s.handler(await signed("ban_user", { user_id: "00000000-0000-0000-0000-0000000000ad", duration: "720h" })),
  );
  assertEquals(admin.body.error.code, "target_is_admin");
});

Deno.test("bridge ban_user duration none from core bridge: lifts login ban (sanction appeal overturned)", async () => {
  const s = setup();
  const res = await json(await s.handler(await signed("ban_user", { user_id: USER, duration: "none" })));
  assertEquals(res.body.data, { user_id: USER, banned_until: null });
  assertEquals(s.authAdmin.bans, [{ id: USER, duration: "none" }]);
  assertEquals(s.rpc.named("svc_audit")[0].args.p_action, "auth.unban");
});

Deno.test("fraud_device_scan (cron apikey): one FR-05 flag per account, no IP or user agent sent to core", async () => {
  const s = setup();
  const res = await json(await s.handler(post({ action: "fraud_device_scan" }, { apikey: "sb_secret_test" })));
  assertEquals(res.body.data, { groups: 1, flagged: 3, failed: 0 });
  assertEquals(s.rpc.named("shared_device_groups")[0].args, { p_since: "6 hours", p_min_accounts: 4 }); // ambang dari config core (AA-13)
  const flags = s.core.named("raise_fraud_flag").map((c) => c.payload);
  assertEquals(flags.map((f) => [f.target_type, f.signal, f.score]), [["profile", "FR-05", 60], [
    "profile",
    "FR-05",
    60,
  ], ["profile", "FR-05", 60]]);
  assertEquals(new Set(flags.map((f) => (f.details as Record<string, unknown>).device_group)).size, 1);
  const wire = JSON.stringify(flags);
  assert(!wire.includes("203.0.113.7") && !wire.includes("Mozilla"));
  assertEquals(
    (await json(await s.handler(post({ action: "fraud_device_scan" }, { apikey: "sb_publishable_x" })))).status,
    401,
  );
});

Deno.test("bridge notify_admins: alert payout → admin_finance + admin_super, idempoten per alert & admin; jenis lain ditolak", async () => {
  const s = setup();
  s.authAdmin.users.set("00000000-0000-0000-0000-0000000000ad", {
    id: "00000000-0000-0000-0000-0000000000ad",
    email: "su@contoh.id",
  });
  const res = await json(
    await s.handler(await signed("notify_admins", { kind: "payout.failed", severity: "warning", alert_id: 42 })),
  );
  assertEquals([res.status, res.body.data.sent], [200, 2]);
  assertEquals(s.rpc.named("svc_admin_ids")[0].args, { p_roles: ["admin_finance", "admin_super"] });
  assertEquals(s.emails.map((e) => e.body.to).sort(), [["andi@contoh.id"], ["su@contoh.id"]]);
  assertEquals(s.emails[0].headers.get("Idempotency-Key")?.startsWith("alert-42-"), true);
  assert(String(s.emails[0].body.subject).includes("payout gagal"));
  assert(String(s.emails[0].body.html).includes("https://admin.clipper.test"));
  const bad = await json(await s.handler(await signed("notify_admins", { kind: "budget.used", alert_id: 1 })));
  assertEquals([bad.status, bad.body.error.code], [400, "invalid_kind"]);
  // CX4: alarm antar-DB sampai ke admin_ops (dulu ditolak → hanya tercatat di dashboard)
  const busAlert = await json(
    await s.handler(await signed("notify_admins", { kind: "bus.stuck", severity: "critical", alert_id: 43 })),
  );
  assertEquals(busAlert.status, 200);
  assertEquals(s.rpc.named("svc_admin_ids").at(-1)!.args, { p_roles: ["admin_ops", "admin_super"] });
  assert(String(s.emails.at(-1)!.body.subject).includes("antrean antar-database macet"));
});

Deno.test("bridge notify_admins: satu email gagal → admin lain tetap dikirimi, respons 503 supaya core mengulang", async () => {
  let calls = 0;
  const s = setup({
    email: () => ({
      send: (m) => {
        calls++;
        return m.to === "andi@contoh.id" ? Promise.reject(new Error("429")) : Promise.resolve({ id: "re_1" });
      },
    }),
  });
  s.authAdmin.users.set("00000000-0000-0000-0000-0000000000ad", {
    id: "00000000-0000-0000-0000-0000000000ad",
    email: "su@contoh.id",
  });
  const res = await json(await s.handler(await signed("notify_admins", { kind: "reconcile.ledger", alert_id: 9 })));
  assertEquals([res.status, res.body.error.code, calls], [503, "email_failed", 2]);
});

// ---- Live Activity iOS (APNs) + receipt Expo -------------------------------------------------------------------------

const PAYOUT = "7d1f0b9e-1c2a-4b3c-8d4e-5f6a7b8c9d01";
const METHOD = "00000000-0000-0000-0000-0000000000f1";
const START_TOKEN = "ab".repeat(32);
const ACTIVITY_TOKEN = "cd".repeat(80);

function liveSetup(
  method: Record<string, unknown> = { id: METHOD, user_id: USER, bank_code: "BCA", account_last4: "4821" },
) {
  const apnsSent: { token: string; payload: { aps: Record<string, unknown> } }[] = [];
  const expoSent: string[] = [];
  const s = setup({
    apns: () => ({
      send: (
        token,
        payload,
      ) => (apnsSent.push({ token, payload: payload as { aps: Record<string, unknown> } }),
        Promise.resolve({ ok: true, status: 200, dead: false })),
    }),
    push: () =>
      Promise.resolve({
        send: () => Promise.resolve(),
        sendExpo: (m) => (expoSent.push(...m.map((x) =>
          x.body
        )),
          Promise.resolve(m.map(() => ({ status: "ok" as const })))),
      }),
    nowS: () => Math.floor(Date.now() / 1000),
  });
  s.rpc
    .on("svc_push_subscriptions", () => [
      {
        kind: "expo",
        endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]",
        p256dh: null,
        auth_secret: null,
        activity_ref: null,
      },
      { kind: "apns_start", endpoint: START_TOKEN, p256dh: null, auth_secret: null, activity_ref: null },
      { kind: "apns_activity", endpoint: ACTIVITY_TOKEN, p256dh: null, auth_secret: null, activity_ref: PAYOUT },
    ])
    .on("svc_payout_methods", () => [{ ...method, account_no_enc: "\\x0a02", account_name: "Andi", kind: "bank" }])
    .on("svc_touch_push", () => null)
    .on("svc_delete_push", () => null);
  return { ...s, apnsSent, expoSent };
}

Deno.test("bridge send_push payout.processing: Live Activity start to apns_start with bank + last4 from identity; Expo push unchanged", async () => {
  const s = liveSetup();
  const res = await json(
    await s.handler(
      await signed("send_push", {
        user_id: USER,
        event: "payout.processing",
        payload: {
          payout_id: PAYOUT,
          payout_method_id: METHOD,
          amount: 147500,
          reward_type: "IDR",
          fee: 2500,
          channel: "instant",
          eta_at: new Date(Date.now() + 120_000).toISOString(),
          bank_code: "EVIL", // nilai dari core dibuang, diganti rekening identity
        },
      }),
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(res.body.data, { sent: 1, removed: 0, failed: 0, live_activity: { sent: 1, removed: 0, failed: 0 } });
  assertEquals(s.rpc.named("svc_payout_methods")[0].args, { p_ids: [METHOD] });
  assertEquals(s.apnsSent.map((x) => x.token), [START_TOKEN]);
  const aps = s.apnsSent[0].payload.aps;
  assertEquals([aps.event, aps["attributes-type"]], ["start", "LiveActivityAttributes"]);
  const props = JSON.parse((aps["content-state"] as { props: string }).props);
  assertEquals([props.amount, props.bank, props.last4, props.status], [147500, "BCA", "4821", "processing"]);
  assert(String((aps.alert as { body: string }).body).includes("BCA •• 4821"));
  assert(s.expoSent[0].includes("BCA •• 4821"));
  assert(!JSON.stringify(s.apnsSent).includes("0a02") && !JSON.stringify(s.apnsSent).includes("EVIL"));
});

Deno.test("bridge send_push: payout method of another user is never shown", async () => {
  const s = liveSetup({
    id: METHOD,
    user_id: "00000000-0000-0000-0000-0000000000b1",
    bank_code: "BCA",
    account_last4: "4821",
  });
  await s.handler(
    await signed("send_push", {
      user_id: USER,
      event: "payout.processing",
      payload: { payout_id: PAYOUT, payout_method_id: METHOD, amount: 1000 },
    }),
  );
  const props = JSON.parse((s.apnsSent[0].payload.aps["content-state"] as { props: string }).props);
  assertEquals([props.bank, props.last4], [null, null]);
  assert(!s.expoSent[0].includes("4821"));
});

Deno.test("bridge send_push payout.paid: Live Activity end to that payout's activity token, then token row deleted", async () => {
  const s = liveSetup();
  const res = await json(
    await s.handler(
      await signed("send_push", {
        user_id: USER,
        event: "payout.paid",
        payload: { payout_id: PAYOUT, amount: "147500" },
      }),
    ),
  );
  assertEquals(res.body.data.live_activity, { sent: 1, removed: 0, failed: 0 });
  assertEquals(s.apnsSent.map((x) => [x.token, x.payload.aps.event]), [[ACTIVITY_TOKEN, "end"]]);
  assertEquals(s.rpc.named("svc_delete_push").map((c) => c.args.p_endpoint), [ACTIVITY_TOKEN]);
});

Deno.test("bridge send_push: APNs off (APNS_* empty) or failing never breaks the normal push", async () => {
  for (
    const apns of [() => null, () => {
      throw new Error("bad key");
    }]
  ) {
    const s = setup({
      apns,
      push: () =>
        Promise.resolve({
          send: () => Promise.resolve(),
          sendExpo: (m) => Promise.resolve(m.map(() => ({ status: "ok" as const }))),
        }),
    });
    s.rpc.on("svc_push_subscriptions", () => [
      { kind: "expo", endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]", p256dh: null, auth_secret: null },
      { kind: "apns_start", endpoint: START_TOKEN, p256dh: null, auth_secret: null },
    ]).on("svc_touch_push", () => null);
    const res = await json(
      await s.handler(
        await signed("send_push", { user_id: USER, event: "payout.processing", payload: { payout_id: PAYOUT } }),
      ),
    );
    assertEquals([res.status, res.body.data], [200, { sent: 1, removed: 0, failed: 0 }]);
  }
});

Deno.test("push_receipts (cron apikey): receipts of due tickets resolved, DeviceNotRegistered token removed; HMAC cannot call it", async () => {
  const asked: string[][] = [];
  const s = setup({
    receipts: (ids) => (asked.push(ids),
      Promise.resolve({
        "t-ok": { status: "ok" as const },
        "t-gone": { status: "error" as const, details: { error: "DeviceNotRegistered" } },
      })),
  });
  s.rpc
    .on("svc_due_push_tickets", () => [
      { ticket: "t-ok", endpoint: "ExponentPushToken[okokokokokokokok]" },
      { ticket: "t-gone", endpoint: "ExponentPushToken[gonegonegonegone]" },
    ])
    .on("svc_resolve_push_tickets", () => ({ resolved: 2, removed: 1, expired: 0 }));
  const res = await json(await s.handler(post({ action: "push_receipts" }, { apikey: "sb_secret_test" })));
  assertEquals(res.body.data, { checked: 2, resolved: 2, removed: 1, expired: 0 });
  assertEquals(asked, [["t-ok", "t-gone"]]);
  assertEquals(s.rpc.named("svc_resolve_push_tickets")[0].args, {
    p_tickets: ["t-ok", "t-gone"],
    p_dead_endpoints: ["ExponentPushToken[gonegonegonegone]"],
  });
  assertEquals((await json(await s.handler(await signed("push_receipts", {})))).body.error.code, "unknown_action");
  assertEquals((await json(await s.handler(post({ action: "push_receipts" })))).status, 401);
});
