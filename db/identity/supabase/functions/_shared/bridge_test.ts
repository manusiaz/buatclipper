import { assertEquals, assertRejects } from "@std/assert";
import { bridgeUrl, createCoreBridge, signBridge, verifyBridge } from "./bridge.ts";
import { HttpError } from "./http.ts";

const SECRET = "core-to-identity-secret";
const NOW = 1_800_000_000;

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (err) {
    if (err instanceof HttpError) return err.code;
    throw err;
  }
  return "ok";
}

Deno.test('bridge: signature = lowercase hex HMAC-SHA256(secret, ts + "." + rawBody) (vector from Python hmac)', async () => {
  const raw = '{"v":1,"action":"check_ids","payload":{}}';
  assertEquals(
    await signBridge(SECRET, "1700000000", raw),
    "2d76c398d4b7ee67982d9424f1ff06d9bfc26603d715f34beb64ec47055ae640",
  );
});

Deno.test("bridge: verify accepts a fresh, correctly signed v1 message", async () => {
  const raw = JSON.stringify({ v: 1, action: "check_ids", payload: { user_ids: [] } });
  const ts = String(NOW - 299);
  const sig = await signBridge(SECRET, ts, raw);
  assertEquals(await verifyBridge({ secret: SECRET, ts, sig, rawBody: raw, nowS: NOW }), {
    action: "check_ids",
    payload: { user_ids: [] },
  });
});

Deno.test("bridge: expiry, tamper, wrong secret, bad version are rejected", async () => {
  const raw = JSON.stringify({ v: 1, action: "send_email", payload: {} });
  const ts = String(NOW);
  const sig = await signBridge(SECRET, ts, raw);
  const v = (o: Partial<Parameters<typeof verifyBridge>[0]>) =>
    code(verifyBridge({ secret: SECRET, ts, sig, rawBody: raw, nowS: NOW, ...o }));
  assertEquals(await v({ nowS: NOW + 301 }), "stale_request");
  assertEquals(await v({ nowS: NOW - 301 }), "stale_request");
  assertEquals(await v({ rawBody: raw.replace("send_email", "send_push") }), "bad_signature");
  assertEquals(await v({ ts: String(NOW + 1) }), "bad_signature"); // ts is part of the signed string
  assertEquals(await v({ secret: "other" }), "bad_signature");
  assertEquals(await v({ sig: sig.toUpperCase() }), "bad_signature");
  assertEquals(await v({ sig: null }), "bad_signature");
  assertEquals(await v({ ts: "abc" }), "bad_timestamp");
  const raw2 = JSON.stringify({ v: 2, action: "send_email", payload: {} });
  assertEquals(await v({ rawBody: raw2, sig: await signBridge(SECRET, ts, raw2) }), "unsupported_version");
});

Deno.test("bridge client: signs outbound calls, unwraps data, retries transient errors only", async () => {
  const seen: { ts: string; sig: string; body: string }[] = [];
  let failFirst = true;
  const fetchFn = ((_url: string | URL | Request, init?: RequestInit) => {
    const h = new Headers(init!.headers);
    seen.push({ ts: h.get("x-bridge-ts")!, sig: h.get("x-bridge-sig")!, body: String(init!.body) });
    if (failFirst) {
      failFirst = false;
      return Promise.resolve(new Response("upstream", { status: 503 }));
    }
    return Promise.resolve(Response.json({ ok: true, data: { id: "b1" } }));
  }) as typeof fetch;
  const core = createCoreBridge({ url: "http://core.test/functions/v1/bridge", secret: "id-to-core", fetchFn });
  assertEquals(await core.invoke("get_batch", { batch_id: "b1" }), { id: "b1" });
  assertEquals(seen.length, 2);
  assertEquals(JSON.parse(seen[1].body), { v: 1, action: "get_batch", payload: { batch_id: "b1" } });
  assertEquals(seen[1].sig, await signBridge("id-to-core", seen[1].ts, seen[1].body));
  const ok = await verifyBridge({ secret: "id-to-core", ts: seen[1].ts, sig: seen[1].sig, rawBody: seen[1].body });
  assertEquals(ok.action, "get_batch");

  let calls = 0;
  const refusing = createCoreBridge({
    url: "http://core.test/bridge",
    secret: "s",
    fetchFn: (() => {
      calls++;
      return Promise.resolve(
        Response.json({ ok: false, error: { code: "batch_not_found", message: "x" } }, { status: 404 }),
      );
    }) as typeof fetch,
  });
  const err = await assertRejects(() => refusing.invoke("get_batch", {}), HttpError);
  assertEquals([err.code, err.status, calls], ["batch_not_found", 404, 1]);
});

Deno.test("bridge URL accepts project URL or functions base", () => {
  assertEquals(bridgeUrl("https://core.supabase.co"), "https://core.supabase.co/functions/v1/bridge");
  assertEquals(bridgeUrl("https://core.supabase.co/functions/v1/"), "https://core.supabase.co/functions/v1/bridge");
});
