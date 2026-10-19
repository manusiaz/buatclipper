import { assertEquals, assertRejects } from "@std/assert";
import { toPgBytea } from "./crypto.ts";
import {
  type DisbursementProvider,
  handleCallback,
  mapXenditStatus,
  MockProvider,
  ProviderRejected,
  runDisburse,
  XenditProvider,
} from "./disburse.ts";
import { HttpError } from "./http.ts";
import { FakeCore, FakeRpc, testCrypto } from "./testing.ts";

const PAYOUT = "00000000-0000-0000-0000-00000000p001".replace("p", "0");
const USER = "00000000-0000-0000-0000-0000000000a1";
const METHOD = "00000000-0000-0000-0000-0000000000m1".replace("m", "0");
const crypto = testCrypto();

Deno.test("xendit status → payout status", () => {
  assertEquals(mapXenditStatus("SUCCEEDED"), "paid");
  for (const s of ["FAILED", "REVERSED", "CANCELLED"]) assertEquals(mapXenditStatus(s), "failed");
  for (const s of ["ACCEPTED", "REQUESTED", "LOCKED"]) assertEquals(mapXenditStatus(s), "processing");
  assertEquals(mapXenditStatus("PENDING_COMPLIANCE_ASSESSMENT"), null);
});

Deno.test("xendit callback parsing (v2 webhook envelope and flat body)", () => {
  const x = new XenditProvider("k");
  assertEquals(
    x.parseCallback({ event: "payout.succeeded", data: { id: "disb-1", reference_id: PAYOUT, status: "SUCCEEDED" } }),
    { payoutId: PAYOUT, providerRef: "disb-1", status: "paid", error: null },
  );
  assertEquals(
    x.parseCallback({
      event: "payout.reversed",
      data: { id: "disb-1", reference_id: PAYOUT, status: "REVERSED", failure_code: "INVALID_DESTINATION" },
    }),
    { payoutId: PAYOUT, providerRef: "disb-1", status: "failed", error: "INVALID_DESTINATION" },
  );
  assertEquals(x.parseCallback({ id: "disb-2", reference_id: PAYOUT, status: "FAILED" })?.status, "failed");
  assertEquals(
    x.parseCallback({ event: "payout.failed", data: { id: "disb-3", reference_id: PAYOUT } })?.status,
    "failed",
  );
  assertEquals(x.parseCallback({ data: { id: "d", reference_id: PAYOUT, status: "ACCEPTED" } }), null);
  assertEquals(x.parseCallback({ data: { id: "d", reference_id: "not-a-uuid", status: "SUCCEEDED" } }), null);
  assertEquals(x.parseCallback(null), null);
});

Deno.test("callback: x-callback-token checked, mapped status forwarded to core mark_instant", async () => {
  const core = new FakeCore({ mark_instant: () => ({ ok: true }) });
  const deps = { core: () => core, provider: () => new XenditProvider("k"), token: () => "tok-123" };
  const body = JSON.stringify({
    event: "payout.succeeded",
    data: { id: "disb-1", reference_id: PAYOUT, status: "SUCCEEDED" },
  });
  await assertRejects(
    () => handleCallback(deps, new Headers({ "x-callback-token": "tok-124" }), body),
    HttpError,
    "token",
  );
  await assertRejects(() => handleCallback(deps, new Headers(), body), HttpError, "token");
  assertEquals(core.calls.length, 0);
  assertEquals(await handleCallback(deps, new Headers({ "x-callback-token": "tok-123" }), body), {
    ignored: false,
    payout_id: PAYOUT,
    status: "paid",
  });
  assertEquals(core.named("mark_instant")[0].payload, {
    payout_id: PAYOUT,
    status: "paid",
    provider_ref: "disb-1",
    error: null,
  });
  const ignored = JSON.stringify({
    event: "payout.accepted",
    data: { id: "d", reference_id: PAYOUT, status: "ACCEPTED" },
  });
  assertEquals(await handleCallback(deps, new Headers({ "x-callback-token": "tok-123" }), ignored), { ignored: true });
});

Deno.test("xendit send: endpoint, Basic auth, idempotency-key = payout id, body", async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const x = new XenditProvider(
    "xnd_secret",
    ((url: string, init: RequestInit) => {
      seen = { url, init };
      return Promise.resolve(Response.json({ id: "disb-9", reference_id: PAYOUT, status: "ACCEPTED" }));
    }) as unknown as typeof fetch,
  );
  const r = await x.send({
    payoutId: PAYOUT,
    kind: "bank",
    bankCode: "BCA",
    accountNo: "8881234567",
    accountName: "Andi Saputra",
    amountIdr: "145000",
    description: "Clipper payout",
  });
  assertEquals(r, { providerRef: "disb-9", status: "processing", error: null });
  assertEquals(seen!.url, "https://api.xendit.co/v2/payouts");
  const h = new Headers(seen!.init.headers);
  assertEquals(h.get("authorization"), "Basic " + btoa("xnd_secret:"));
  assertEquals(h.get("idempotency-key"), PAYOUT);
  assertEquals(JSON.parse(String(seen!.init.body)), {
    reference_id: PAYOUT,
    channel_code: "ID_BCA",
    channel_properties: { account_number: "8881234567", account_holder_name: "Andi Saputra" },
    amount: 145000,
    currency: "IDR",
    description: "Clipper payout",
  });
});

Deno.test("xendit send: 4xx rejected for good, 5xx transient, 401 config, 409 reads the existing payout", async () => {
  const mk = (status: number, body: unknown, then?: unknown) => {
    let n = 0;
    return new XenditProvider(
      "k",
      (() =>
        Promise.resolve(
          Response.json(n++ === 0 ? body : then, { status: n === 1 ? status : 200 }),
        )) as unknown as typeof fetch,
    );
  };
  const req = {
    payoutId: PAYOUT,
    kind: "bank" as const,
    bankCode: "BCA",
    accountNo: "1",
    accountName: "A",
    amountIdr: "1",
    description: "d",
  };
  const rej = await assertRejects(() => mk(400, { error_code: "INVALID_DESTINATION" }).send(req), ProviderRejected);
  assertEquals(rej.code, "INVALID_DESTINATION");
  assertEquals((await assertRejects(() => mk(503, {}).send(req), HttpError)).status, 503);
  assertEquals((await assertRejects(() => mk(401, {}).send(req), HttpError)).code, "provider_auth");
  const dup = await mk(409, { error_code: "DUPLICATE_ERROR" }, {
    data: [{ id: "disb-old", reference_id: PAYOUT, status: "SUCCEEDED" }],
  }).send(req);
  assertEquals(dup, { providerRef: "disb-old", status: "paid", error: null });
});

async function fixture(
  over: { method?: Record<string, unknown>; kyc?: Record<string, unknown>; payout?: Record<string, unknown> } = {},
) {
  const enc = await crypto.encrypt("payout.account_no", "8881234567");
  const rpc = new FakeRpc({
    svc_payout_methods: () => [{
      id: METHOD,
      user_id: USER,
      kind: "bank",
      bank_code: "BCA",
      account_no_enc: toPgBytea(enc.ciphertext),
      account_last4: "4567",
      enc_key_version: enc.version,
      account_name: "andi  saputra",
      disabled_at: null,
      blocked: false,
      ...over.method,
    }],
    svc_kyc: () => [{
      user_id: USER,
      legal_name: "Andi Saputra",
      nik_enc: null,
      enc_key_version: null,
      status: "approved",
      closed: false,
      ...over.kyc,
    }],
  });
  const core = new FakeCore({
    get_payout: () => ({
      id: PAYOUT,
      user_id: USER,
      method_id: METHOD,
      amount: "150000.00",
      fee: "5000.00",
      channel: "instant",
      status: "requested",
      ...over.payout,
    }),
    mark_instant: () => ({ ok: true }),
  });
  const sent: unknown[] = [];
  const provider: DisbursementProvider = {
    name: "fake",
    send: (r) => {
      sent.push(r);
      return Promise.resolve({ providerRef: "disb-1", status: "processing" });
    },
    parseCallback: () => null,
  };
  return { rpc, core, sent, deps: { core: () => core, rpc, crypto: () => crypto, provider: () => provider } };
}

Deno.test("disburse: decrypts account, sends net amount (amount − fee), marks processing", async () => {
  const f = await fixture();
  assertEquals(await runDisburse(f.deps, PAYOUT), {
    payout_id: PAYOUT,
    status: "processing",
    provider_ref: "disb-1",
    error: null,
  });
  assertEquals(f.sent, [{
    payoutId: PAYOUT,
    kind: "bank",
    bankCode: "BCA",
    accountNo: "8881234567",
    accountName: "andi  saputra",
    amountIdr: "145000",
    description: `Clipper payout ${PAYOUT.slice(0, 8)}`,
  }]);
  assertEquals(f.core.named("mark_instant").map((c) => c.payload), [
    { payout_id: PAYOUT, status: "processing", provider_ref: "disb-1", error: null },
  ]);
});

Deno.test("disburse: owner mismatch / disabled / KYC / name → failed without calling the provider", async () => {
  const cases: [Parameters<typeof fixture>[0], string][] = [
    [{ method: { user_id: "00000000-0000-0000-0000-0000000000b1" } }, "method_owner_mismatch"],
    [{ method: { disabled_at: "2026-10-01T00:00:00Z" } }, "method_disabled"],
    [{ method: { blocked: true } }, "method_disabled"],
    [{ kyc: { status: "pending" } }, "kyc_not_approved"],
    [{ method: { account_name: "Andi S" } }, "name_mismatch"],
    [{ payout: { fee: "150000.00" } }, "invalid_amount"],
    [{ payout: { amount: "150000.50", fee: "0" } }, "invalid_amount"],
  ];
  for (const [over, reason] of cases) {
    const f = await fixture(over);
    assertEquals((await runDisburse(f.deps, PAYOUT)).error, reason);
    assertEquals(f.sent.length, 0, reason);
    assertEquals(f.core.named("mark_instant")[0].payload, {
      payout_id: PAYOUT,
      status: "failed",
      provider_ref: null,
      error: reason,
    });
  }
});

Deno.test("disburse: non-instant refused, settled payout is an idempotent no-op", async () => {
  const batch = await fixture({ payout: { channel: "batch" } });
  assertEquals((await assertRejects(() => runDisburse(batch.deps, PAYOUT), HttpError)).code, "not_instant");
  const paid = await fixture({ payout: { status: "paid" } });
  assertEquals(await runDisburse(paid.deps, PAYOUT), { payout_id: PAYOUT, status: "paid", skipped: true });
  assertEquals(paid.sent.length + paid.core.named("mark_instant").length, 0);
});

Deno.test("disburse: provider rejection fails the payout; transient error leaves it for retry", async () => {
  const f = await fixture();
  f.deps.provider = () => ({
    name: "x",
    send: () => Promise.reject(new ProviderRejected("INVALID_DESTINATION")),
    parseCallback: () => null,
  });
  assertEquals((await runDisburse(f.deps, PAYOUT)).status, "failed");
  assertEquals(f.core.named("mark_instant")[0].payload.error, "INVALID_DESTINATION");
  const g = await fixture();
  g.deps.provider = () => ({
    name: "x",
    send: () => Promise.reject(new HttpError(503, "provider_unavailable")),
    parseCallback: () => null,
  });
  await assertRejects(() => runDisburse(g.deps, PAYOUT), HttpError, "provider_unavailable");
  assertEquals(g.core.named("mark_instant").length, 0);
});

Deno.test("disburse: mock provider succeeds immediately (processing → paid)", async () => {
  const f = await fixture();
  f.deps.provider = () => new MockProvider();
  assertEquals((await runDisburse(f.deps, PAYOUT)).status, "paid");
  assertEquals(f.core.named("mark_instant").map((c) => c.payload.status), ["processing", "paid"]);
});
