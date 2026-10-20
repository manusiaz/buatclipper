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
      (a.p_roles as string[]).includes("admin_finance") ? [USER, "00000000-0000-0000-0000-0000000000ad"] : [],
    shared_device_groups: () => [
      {
        ip: "203.0.113.7",
        user_agent: "Mozilla/5.0 X",
        user_ids: [USER, "00000000-0000-0000-0000-0000000000b1", "00000000-0000-0000-0000-0000000000c1"],
      },
    ],
  });
  const core = new FakeCore({ raise_fraud_flag: () => ({ id: "f1" }) });
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

Deno.test("fraud_device_scan (cron apikey): one FR-05 flag per account, no IP or user agent sent to core", async () => {
  const s = setup();
  const res = await json(await s.handler(post({ action: "fraud_device_scan" }, { apikey: "sb_secret_test" })));
  assertEquals(res.body.data, { groups: 1, flagged: 3, failed: 0 });
  assertEquals(s.rpc.named("shared_device_groups")[0].args, { p_since: "1 day", p_min_accounts: 3 });
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
