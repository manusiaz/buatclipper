import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { createTikTok } from "./tiktok.ts";
import { AdapterError, isMetrics, Retryable, type StoredToken, TokenExpired } from "./types.ts";
import token from "./testdata/tiktok_token.json" with { type: "json" };
import userInfo from "./testdata/tiktok_user_info.json" with { type: "json" };
import query from "./testdata/tiktok_video_query.json" with { type: "json" };
import invalid from "./testdata/tiktok_token_invalid.json" with { type: "json" };
import rateLimit from "./testdata/tiktok_rate_limit.json" with { type: "json" };

const T: StoredToken = {
  v: 1,
  access_token: "act.x",
  refresh_token: "rft.x",
  meta: { open_id: "o1", username: "clippersatu" },
};
const cfg = { clientKey: "ck", clientSecret: "cs" };

Deno.test("tiktok: exchangeCode + profile", async () => {
  const m = mockFetch(
    on("POST", "open.tiktokapis.com/v2/oauth/token/", () => jsonRes(200, token)),
    on("GET", "open.tiktokapis.com/v2/user/info/", () => jsonRes(200, userInfo)),
  );
  const a = createTikTok({ ...cfg, fetch: m.fetch });
  const t = await a.exchangeCode("code1", "https://app.test/cb");
  const sent = new URLSearchParams(m.calls[0].body);
  assert.equal(sent.get("client_key"), "ck");
  assert.equal(sent.get("grant_type"), "authorization_code");
  assert.equal(t.meta?.open_id, token.open_id);
  assert.ok(t.expires_at && Date.parse(t.expires_at) > Date.now());
  const p = await a.profile(t);
  assert.deepEqual([p.externalId, p.handle, p.followers], [token.open_id, "clippersatu", 1520]);
  assert.equal(m.calls[1].headers.get("authorization"), `Bearer ${token.access_token}`);
});

Deno.test("tiktok: scope video.list ditolak user → scope_missing", async () => {
  const m = mockFetch(
    on("POST", "open.tiktokapis.com/v2/oauth/token/", () => jsonRes(200, { ...token, scope: "user.info.basic" })),
  );
  await assert.rejects(
    createTikTok({ ...cfg, fetch: m.fetch }).exchangeCode("c", "https://app.test/cb"),
    (e) => e instanceof AdapterError && e.code === "scope_missing",
  );
});

Deno.test("tiktok: fetchMetrics memetakan view/like/comment/share dan video hilang = gone", async () => {
  const m = mockFetch(on("POST", "open.tiktokapis.com/v2/video/query/", () => jsonRes(200, query)));
  const r = await createTikTok({ ...cfg, fetch: m.fetch }).fetchMetrics(T, [
    "7080217258529732869",
    "7080217258529732870",
  ]);
  const body = JSON.parse(m.calls[0].body);
  assert.deepEqual(body.filters.video_ids, ["7080217258529732869", "7080217258529732870"]);
  assert.ok(m.calls[0].url.searchParams.get("fields")!.includes("view_count"));
  assert.ok(isMetrics(r[0]));
  assert.deepEqual([r[0].views, r[0].likes, r[0].comments, r[0].shares], [15234, 812, 44, 19]);
  assert.deepEqual(r[1], { postId: "7080217258529732870", gone: true, reason: "not_found_or_private" });
});

Deno.test("tiktok: video/query dibatch maks 20 id", async () => {
  const m = mockFetch(
    on(
      "POST",
      "open.tiktokapis.com/v2/video/query/",
      () => jsonRes(200, { data: { videos: [] }, error: { code: "ok" } }),
    ),
  );
  const ids = Array.from({ length: 45 }, (_, i) => String(7000000000000000000n + BigInt(i)));
  await createTikTok({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ids);
  assert.deepEqual(m.calls.map((c) => JSON.parse(c.body).filters.video_ids.length), [20, 20, 5]);
});

Deno.test("tiktok: 401 access_token_invalid → TokenExpired; 429 → Retryable", async () => {
  const expired = mockFetch(on("POST", "open.tiktokapis.com/v2/video/query/", () => jsonRes(401, invalid)));
  await assert.rejects(createTikTok({ ...cfg, fetch: expired.fetch }).fetchMetrics(T, ["1"]), TokenExpired);
  const limited = mockFetch(on("POST", "open.tiktokapis.com/v2/video/query/", () => jsonRes(429, rateLimit)));
  await assert.rejects(createTikTok({ ...cfg, fetch: limited.fetch }).fetchMetrics(T, ["1"]), Retryable);
  const down = mockFetch(() => Promise.reject(new TypeError("connection reset")));
  await assert.rejects(createTikTok({ ...cfg, fetch: down.fetch }).fetchMetrics(T, ["1"]), Retryable);
});

Deno.test("tiktok: getPost dari URL; video akun lain = not_owner", async () => {
  const own = mockFetch(on("POST", "open.tiktokapis.com/v2/video/query/", () => jsonRes(200, query)));
  const v = await createTikTok({ ...cfg, fetch: own.fetch }).getPost(
    T,
    "https://www.tiktok.com/@clippersatu/video/7080217258529732869?lang=id",
  );
  assert.deepEqual([v.postId, v.durationSec, v.caption], [
    "7080217258529732869",
    34,
    "Highlight MPL #mplid @studiosatu",
  ]);
  assert.equal(v.postedAt, new Date(1790000000 * 1000).toISOString());
  const other = mockFetch(
    on(
      "POST",
      "open.tiktokapis.com/v2/video/query/",
      () => jsonRes(200, { data: { videos: [] }, error: { code: "ok" } }),
    ),
  );
  await assert.rejects(
    createTikTok({ ...cfg, fetch: other.fetch }).getPost(T, "7080217258529732869"),
    (e) => e instanceof AdapterError && e.code === "not_owner",
  );
  await assert.rejects(
    createTikTok({ ...cfg, fetch: other.fetch }).getPost(T, "https://example.com/x"),
    (e) => e instanceof AdapterError && e.code === "bad_url",
  );
});

Deno.test("tiktok: refreshToken menyimpan refresh_token baru; invalid_grant → TokenExpired", async () => {
  const ok = mockFetch(on("POST", "open.tiktokapis.com/v2/oauth/token/", (c) => {
    assert.equal(new URLSearchParams(c.body).get("grant_type"), "refresh_token");
    return jsonRes(200, { ...token, refresh_token: "rft.new" });
  }));
  const t = await createTikTok({ ...cfg, fetch: ok.fetch }).refreshToken(T);
  assert.equal(t.refresh_token, "rft.new");
  assert.equal(t.meta?.username, "clippersatu");
  const bad = mockFetch(
    on(
      "POST",
      "open.tiktokapis.com/v2/oauth/token/",
      () => jsonRes(400, { error: "invalid_grant", error_description: "Refresh token is invalid or expired." }),
    ),
  );
  await assert.rejects(createTikTok({ ...cfg, fetch: bad.fetch }).refreshToken(T), TokenExpired);
});
