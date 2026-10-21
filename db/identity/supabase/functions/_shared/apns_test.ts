import { assert, assertEquals } from "@std/assert";
import {
  ACTIVITY_URL,
  type ApnsConfig,
  apnsConfig,
  type ApnsResult,
  type ApnsSender,
  apnsSender,
  endPayload,
  PROVIDER_TOKEN_TTL_S,
  sendPayoutActivity,
  startPayload,
} from "./apns.ts";
import { b64decode, b64encode } from "./crypto.ts";
import { FakeRpc } from "./testing.ts";

const USER = "00000000-0000-0000-0000-0000000000a1";
const PAYOUT = "7d1f0b9e-1c2a-4b3c-8d4e-5f6a7b8c9d01";
const START = "ab".repeat(32);
const ACTIVITY = "cd".repeat(80);

async function testKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = b64encode(der).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

function cfg(pem: string, over: Partial<ApnsConfig> = {}): ApnsConfig {
  return {
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKey: pem,
    bundleId: "id.clipper.app",
    sandbox: false,
    ...over,
  };
}

type Call = { url: string; headers: Headers; body: Record<string, unknown> };
function fakeFetch(respond: (url: string) => Response = () => new Response(null, { status: 200 })) {
  const calls: Call[] = [];
  const fn = ((url: string, init: RequestInit) => {
    calls.push({ url, headers: new Headers(init.headers), body: JSON.parse(String(init.body)) });
    return Promise.resolve(respond(url));
  }) as unknown as typeof fetch;
  return { calls, fn };
}

const b64urlJson = (s: string) =>
  JSON.parse(new TextDecoder().decode(b64decode(s.replace(/-/g, "+").replace(/_/g, "/"))));

Deno.test("apns provider JWT: ES256 header kid/alg, claims iss/iat, signature verifiable with the .p8 public key", async () => {
  const { pem, publicKey } = await testKey();
  const f = fakeFetch();
  await apnsSender(cfg(pem), { fetchFn: f.fn, nowS: () => 1_760_000_000 }).send(START, { aps: {} });
  const auth = f.calls[0].headers.get("authorization")!;
  assert(auth.startsWith("bearer "));
  const [h, c, sig] = auth.slice(7).split(".");
  assertEquals(b64urlJson(h), { alg: "ES256", kid: "ABC123DEFG" });
  assertEquals(b64urlJson(c), { iss: "TEAM123456", iat: 1_760_000_000 });
  const raw = b64decode(sig.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(sig.length / 4) * 4, "="));
  assertEquals(raw.length, 64); // r||s (JOSE), bukan DER
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      raw as BufferSource,
      new TextEncoder().encode(`${h}.${c}`),
    ),
  );
});

Deno.test("apns provider JWT cached ~50 min, renewed after; 403 provider token rejected → renewed on next send", async () => {
  const { pem } = await testKey();
  let now = 1_760_000_000;
  let status = 200;
  const f = fakeFetch(() =>
    status === 200 ? new Response(null, { status }) : Response.json({ reason: "ExpiredProviderToken" }, { status })
  );
  const s = apnsSender(cfg(pem), { fetchFn: f.fn, nowS: () => now });
  const iat = () => b64urlJson(f.calls.at(-1)!.headers.get("authorization")!.slice(7).split(".")[1]).iat;
  await s.send(START, {});
  now += PROVIDER_TOKEN_TTL_S - 1;
  await s.send(START, {});
  assertEquals(iat(), 1_760_000_000);
  now += 1;
  await s.send(START, {});
  assertEquals(iat(), now);
  status = 403;
  assertEquals((await s.send(START, {})).dead, false);
  status = 200;
  now += 5;
  await s.send(START, {});
  assertEquals(iat(), now);
});

Deno.test("apns request: production host, /3/device/<token>, liveactivity headers; sandbox host when APNS_ENV=sandbox", async () => {
  const { pem } = await testKey();
  const f = fakeFetch();
  const r = await apnsSender(cfg(pem), { fetchFn: f.fn }).send(START, { aps: { event: "start" } });
  assertEquals(r, { ok: true, status: 200, dead: false });
  const c = f.calls[0];
  assertEquals(c.url, `https://api.push.apple.com/3/device/${START}`);
  assertEquals(c.headers.get("apns-push-type"), "liveactivity");
  assertEquals(c.headers.get("apns-topic"), "id.clipper.app.push-type.liveactivity");
  assertEquals(c.headers.get("apns-priority"), "10");
  assertEquals(c.body, { aps: { event: "start" } });
  await apnsSender(cfg(pem, { sandbox: true }), { fetchFn: f.fn }).send(START, {});
  assertEquals(f.calls[1].url, `https://api.sandbox.push.apple.com/3/device/${START}`);
});

Deno.test("apns result: 410 and 400 BadDeviceToken are dead tokens; other errors, network and bad key are not", async () => {
  const { pem } = await testKey();
  const send = async (res: () => Response | Promise<Response>, key = pem): Promise<ApnsResult> =>
    await apnsSender(cfg(key), { fetchFn: (() => Promise.resolve(res())) as unknown as typeof fetch }).send(START, {});
  assertEquals(await send(() => Response.json({ reason: "Unregistered" }, { status: 410 })), {
    ok: false,
    status: 410,
    reason: "Unregistered",
    dead: true,
  });
  assertEquals((await send(() => Response.json({ reason: "BadDeviceToken" }, { status: 400 }))).dead, true);
  assertEquals((await send(() => Response.json({ reason: "DeviceTokenNotForTopic" }, { status: 400 }))).dead, false);
  assertEquals((await send(() => Response.json({ reason: "TooManyRequests" }, { status: 429 }))).dead, false);
  assertEquals((await send(() => Promise.reject(new TypeError("dns")))).reason, "network");
  assertEquals(
    await send(
      () => new Response(null, { status: 200 }),
      "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
    ),
    {
      ok: false,
      status: 0,
      reason: "provider_key",
      dead: false,
    },
  );
});

Deno.test("apnsConfig: any APNS_* missing → null (feature off); PEM with literal \\n accepted; sandbox flag", async () => {
  const { pem } = await testKey();
  const env: Record<string, string> = {
    APNS_KEY_ID: "ABC123DEFG",
    APNS_TEAM_ID: "TEAM123456",
    APNS_PRIVATE_KEY: pem.replace(/\n/g, "\\n"),
    APNS_BUNDLE_ID: "id.clipper.app",
  };
  const c = apnsConfig((n) => env[n]);
  assertEquals([c?.sandbox, c?.bundleId], [false, "id.clipper.app"]);
  assertEquals(apnsConfig((n) => ({ ...env, APNS_ENV: "sandbox" })[n])?.sandbox, true);
  for (const k of Object.keys(env)) assertEquals(apnsConfig((n) => (n === k ? "" : env[n])), null);
  const f = fakeFetch();
  assertEquals((await apnsSender(c!, { fetchFn: f.fn }).send(START, {})).ok, true);
});

Deno.test("startPayload: push-to-start LiveActivityAttributes, props JSON for the Payout activity, stale-date after eta", () => {
  const now = 1_760_000_000;
  const p = startPayload(
    {
      payout_id: PAYOUT,
      payout_method_id: "00000000-0000-0000-0000-0000000000f1",
      amount: "147500.00",
      reward_type: "IDR",
      fee: 2500,
      channel: "instant",
      eta_at: "2025-10-09T08:55:20+00:00",
      bank_code: "BCA",
      account_last4: "4821",
      account_no: "1234564821", // tidak pernah dikirim walau ada di payload
    },
    { title: "Penarikan Rp147.500 sedang diproses", body: "Lagi ditransfer ke BCA •• 4821." },
    now,
  );
  assertEquals(p, {
    aps: {
      timestamp: now,
      event: "start",
      "attributes-type": "LiveActivityAttributes",
      attributes: { url: ACTIVITY_URL },
      "content-state": {
        name: "Payout",
        props: JSON.stringify({
          payoutId: PAYOUT,
          amount: 147500,
          bank: "BCA",
          last4: "4821",
          etaAt: "2025-10-09T08:55:20.000Z",
          startedAt: "2025-10-09T08:53:20.000Z",
          status: "processing",
        }),
      },
      "stale-date": now + 120 + 900, // eta + 15 menit
      alert: { title: "Penarikan Rp147.500 sedang diproses", body: "Lagi ditransfer ke BCA •• 4821." },
    },
  });
  assert(!JSON.stringify(p).includes("1234564821"));
  const noEta = startPayload({ amount: "x" }, { title: "t", body: "b" }, now);
  assertEquals(noEta.aps["stale-date"], now + 8 * 3600);
  assertEquals(JSON.parse(noEta.aps["content-state"].props).amount, null);
});

Deno.test("endPayload: event end, status paid | failed in props, dismissal-date", () => {
  const now = 1_760_000_000;
  const paid = endPayload({ amount: 147500, bank_code: "BCA", account_last4: "4821", paid_at: "x" }, "paid", now);
  assertEquals(paid.aps.event, "end");
  assertEquals(paid.aps.timestamp, now);
  assertEquals(paid.aps["dismissal-date"], now + 3600);
  assertEquals(paid.aps["content-state"].name, "Payout");
  assertEquals(JSON.parse(paid.aps["content-state"].props), {
    payoutId: null,
    amount: 147500,
    bank: "BCA",
    last4: "4821",
    etaAt: null,
    startedAt: null,
    status: "paid",
  });
  assertEquals(Object.keys(paid.aps).sort(), ["content-state", "dismissal-date", "event", "timestamp"]);
  assertEquals(JSON.parse(endPayload({ bank_code: "x y" }, "failed", now).aps["content-state"].props).bank, null);
});

function liveSetup(subs: Record<string, unknown>[], respond: Record<string, number> = {}) {
  const rpc = new FakeRpc({
    svc_push_subscriptions: () => subs,
    svc_delete_push: () => null,
    svc_touch_push: () => null,
  });
  const sent: { token: string; payload: Record<string, unknown> }[] = [];
  const sender: ApnsSender = {
    send(token, payload) {
      sent.push({ token, payload: payload as Record<string, unknown> });
      const status = respond[token] ?? 200;
      return Promise.resolve({ ok: status === 200, status, dead: status === 410 });
    },
  };
  return { rpc, sent, deps: { rpc, apns: () => sender, nowS: () => 1_760_000_000 } };
}

const SUBS = [
  { kind: "expo", endpoint: "ExponentPushToken[aaaaaaaaaaaaaaaa]", activity_ref: null },
  { kind: "apns_start", endpoint: START, activity_ref: null },
  { kind: "apns_start", endpoint: "ef".repeat(32), activity_ref: null },
  { kind: "apns_activity", endpoint: ACTIVITY, activity_ref: PAYOUT },
  { kind: "apns_activity", endpoint: "12".repeat(40), activity_ref: "lain" },
];

Deno.test("sendPayoutActivity payout.processing: start to every apns_start token, dead token deleted, alive touched", async () => {
  const s = liveSetup(SUBS, { ["ef".repeat(32)]: 410 });
  const res = await sendPayoutActivity(s.deps, USER, "payout.processing", { payout_id: PAYOUT, amount: 1000 }, {
    title: "t",
    body: "b",
  });
  assertEquals(res, { sent: 1, removed: 1, failed: 0 });
  assertEquals(s.sent.map((x) => x.token).sort(), [START, "ef".repeat(32)].sort());
  assertEquals((s.sent[0].payload.aps as Record<string, unknown>).event, "start");
  assertEquals(s.rpc.named("svc_delete_push").map((c) => c.args.p_endpoint), ["ef".repeat(32)]);
  assertEquals(s.rpc.named("svc_touch_push").map((c) => c.args.p_endpoint), [START]);
});

Deno.test("sendPayoutActivity paid/failed/cancelled: end only to the activity token of that payout, then row deleted", async () => {
  for (
    const [event, status] of [["payout.paid", "paid"], ["payout.failed", "failed"], ["payout.cancelled", "failed"]]
  ) {
    const s = liveSetup(SUBS, { [ACTIVITY]: 500 });
    const res = await sendPayoutActivity(s.deps, USER, event, { payout_id: PAYOUT, amount: 1000 }, {
      title: "t",
      body: "b",
    });
    assertEquals(res, { sent: 0, removed: 0, failed: 1 });
    assertEquals(s.sent.map((x) => x.token), [ACTIVITY]);
    const aps = s.sent[0].payload.aps as Record<string, Record<string, string>>;
    assertEquals([aps.event, JSON.parse(aps["content-state"].props).status], ["end", status]);
    assertEquals(s.rpc.named("svc_delete_push").map((c) => c.args.p_endpoint), [ACTIVITY]); // tetap dihapus walau gagal
  }
});

Deno.test("sendPayoutActivity: other events or APNS_* missing → null without touching the database", async () => {
  const s = liveSetup(SUBS);
  assertEquals(await sendPayoutActivity(s.deps, USER, "kyc.approved", {}, { title: "t", body: "b" }), null);
  assertEquals(
    await sendPayoutActivity({ ...s.deps, apns: () => null }, USER, "payout.processing", {}, { title: "t", body: "b" }),
    null,
  );
  assertEquals([s.rpc.calls.length, s.sent.length], [0, 0]);
  const noRef = await sendPayoutActivity(s.deps, USER, "payout.paid", {}, { title: "t", body: "b" });
  assertEquals([noRef, s.sent.length], [{ sent: 0, removed: 0, failed: 0 }, 0]);
});
