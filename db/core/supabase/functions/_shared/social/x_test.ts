import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { createX, tweetIdFrom } from "./x.ts";
import { AdapterError, isMetrics, Retryable, type StoredToken, TokenExpired } from "./types.ts";
import lookup from "./testdata/x_lookup.json" with { type: "json" };

const T: StoredToken = { v: 1, access_token: "xat", refresh_token: "xrt", meta: { user_id: "2244994945", username: "clippersatu" } };
const cfg = { clientId: "xid", clientSecret: "xsecret" };

Deno.test("x: authorize wajib PKCE S256; exchangeCode pakai Basic auth + code_verifier", async () => {
  const a0 = createX(cfg);
  assert.throws(() => a0.authorizeUrl("https://app.test/cb", "st"), AdapterError);
  const url = new URL(a0.authorizeUrl("https://app.test/cb", "st", "chal"));
  assert.equal(url.origin + url.pathname, "https://x.com/i/oauth2/authorize");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  const m = mockFetch(on("POST", "api.x.com/2/oauth2/token", (c) => {
    assert.equal(c.headers.get("authorization"), `Basic ${btoa("xid:xsecret")}`);
    assert.equal(new URLSearchParams(c.body).get("code_verifier"), "verif");
    return jsonRes(200, { token_type: "bearer", expires_in: 7200, access_token: "xat", scope: "tweet.read users.read offline.access", refresh_token: "xrt" });
  }));
  const t = await createX({ ...cfg, fetch: m.fetch }).exchangeCode("c", "https://app.test/cb", "verif");
  assert.deepEqual([t.access_token, t.refresh_token], ["xat", "xrt"]);
  await assert.rejects(createX(cfg).exchangeCode("c", "https://app.test/cb"), (e) => e instanceof AdapterError && e.code === "oauth_failed");
});

Deno.test("x: fetchMetrics impression_count = views; post tidak ditemukan = gone", async () => {
  const m = mockFetch(on("GET", "api.x.com/2/tweets", () => jsonRes(200, lookup)));
  const r = await createX({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ["1840000000000000001", "1840000000000000002"]);
  assert.equal(m.calls[0].url.searchParams.get("ids"), "1840000000000000001,1840000000000000002");
  assert.ok(isMetrics(r[0]));
  assert.deepEqual([r[0].views, r[0].likes, r[0].comments, r[0].shares, r[0].extra.video_views], [9876, 40, 2, 5, 4321]);
  assert.deepEqual(r[1], { postId: "1840000000000000002", gone: true, reason: "Not Found Error" });
});

Deno.test("x: 401 → TokenExpired, 429 → Retryable; refresh menyimpan refresh_token baru (rotasi)", async () => {
  await assert.rejects(createX({ ...cfg, fetch: mockFetch(() => jsonRes(401, { title: "Unauthorized", status: 401 })).fetch }).fetchMetrics(T, ["1"]), TokenExpired);
  await assert.rejects(createX({ ...cfg, fetch: mockFetch(() => jsonRes(429, { title: "Too Many Requests" })).fetch }).fetchMetrics(T, ["1"]), Retryable);
  const m = mockFetch(on("POST", "api.x.com/2/oauth2/token", () => jsonRes(200, { access_token: "xat2", refresh_token: "xrt2", expires_in: 7200 })));
  const t = await createX({ ...cfg, fetch: m.fetch }).refreshToken(T);
  assert.deepEqual([t.access_token, t.refresh_token, t.meta?.user_id], ["xat2", "xrt2", "2244994945"]);
});

Deno.test("x: getPost cek author_id; parser URL", async () => {
  const other = { ...lookup, data: [{ ...lookup.data[0], author_id: "1" }] };
  const m = mockFetch(on("GET", "api.x.com/2/tweets", () => jsonRes(200, other)));
  await assert.rejects(createX({ ...cfg, fetch: m.fetch }).getPost(T, "https://x.com/someone/status/1840000000000000001"), (e) => e instanceof AdapterError && e.code === "not_owner");
  const own = mockFetch(on("GET", "api.x.com/2/tweets", () => jsonRes(200, lookup)));
  const v = await createX({ ...cfg, fetch: own.fetch }).getPost(T, "https://twitter.com/clippersatu/status/1840000000000000001?s=20");
  assert.deepEqual([v.postId, v.durationSec, v.url], ["1840000000000000001", 30, "https://x.com/clippersatu/status/1840000000000000001"]);
  assert.equal(tweetIdFrom("https://x.com.evil.io/a/status/1840000000000000001"), null);
});

Deno.test("x: listVideos hanya post ber-video, start_time tanpa milidetik", async () => {
  const text = { id: "1840000000000000009", text: "teks saja", author_id: "2244994945", created_at: "2026-10-02T10:00:00.000Z" };
  const m = mockFetch(on("GET", "api.x.com/2/users/2244994945/tweets", (c) => {
    assert.equal(c.url.searchParams.get("start_time"), "2026-09-30T00:00:00Z");
    assert.equal(c.url.searchParams.get("exclude"), "retweets,replies");
    return jsonRes(200, { data: [...lookup.data, text], includes: lookup.includes });
  }));
  const vids = await createX({ ...cfg, fetch: m.fetch }).listVideos(T, "2026-09-30T00:00:00.000Z");
  assert.deepEqual(vids.map((v) => v.postId), ["1840000000000000001"]);
});
