import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { createFacebook, fbVideoIdFrom } from "./facebook.ts";
import { AdapterError, isMetrics, Retryable, type StoredToken, TokenExpired } from "./types.ts";
import video from "./testdata/fb_video.json" with { type: "json" };
import expired from "./testdata/graph_token_expired.json" with { type: "json" };
import missing from "./testdata/graph_object_missing.json" with { type: "json" };
import rateLimit from "./testdata/graph_rate_limit.json" with { type: "json" };

const G = "graph.facebook.com/v23.0";
const T: StoredToken = { v: 1, access_token: "EAAPage", expires_at: null, meta: { page_id: "99887766" } };
const cfg = { appId: "fb-app", appSecret: "fb-secret" };

Deno.test("facebook: exchangeCode memilih Page; lebih dari satu Page tanpa page_id = page_ambiguous", async () => {
  const pages = [{ id: "99887766", name: "Clipper Page", access_token: "EAAPage" }, {
    id: "11",
    name: "Lain",
    access_token: "EAAOther",
  }];
  const m = mockFetch(
    on(
      "GET",
      `${G}/oauth/access_token`,
      (c) =>
        jsonRes(200, {
          access_token: c.url.searchParams.get("grant_type") === "fb_exchange_token" ? "EAALong" : "EAAShort",
          token_type: "bearer",
        }),
    ),
    on("GET", `${G}/me/accounts`, () => jsonRes(200, { data: pages })),
  );
  const a = createFacebook({ ...cfg, fetch: m.fetch });
  await assert.rejects(
    a.exchangeCode("c", "https://app.test/cb"),
    (e) => e instanceof AdapterError && e.code === "page_ambiguous",
  );
  const t = await a.exchangeCode("c", "https://app.test/cb", undefined, { pageId: "99887766" });
  assert.deepEqual([t.access_token, t.expires_at, t.meta?.page_id], ["EAAPage", null, "99887766"]);
});

Deno.test("facebook: fetchMetrics views + likes/comments summary + shares post", async () => {
  const m = mockFetch(
    on("GET", `${G}/1234567890123456`, () => jsonRes(200, video)),
    on(
      "GET",
      `${G}/99887766_1234567890123456`,
      () => jsonRes(200, { id: "99887766_1234567890123456", shares: { count: 3 } }),
    ),
  );
  const [r] = await createFacebook({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ["1234567890123456"]);
  assert.ok(isMetrics(r));
  assert.deepEqual([r.views, r.likes, r.comments, r.shares], [4321, 55, 4, 3]);
});

Deno.test("facebook: gone / 190 / rate limit", async () => {
  const gone = mockFetch(() => jsonRes(400, missing));
  assert.equal(
    ((await createFacebook({ ...cfg, fetch: gone.fetch }).fetchMetrics(T, ["1"]))[0] as { gone?: boolean }).gone,
    true,
  );
  await assert.rejects(
    createFacebook({ ...cfg, fetch: mockFetch(() => jsonRes(400, expired)).fetch }).fetchMetrics(T, ["1"]),
    TokenExpired,
  );
  await assert.rejects(
    createFacebook({ ...cfg, fetch: mockFetch(() => jsonRes(400, rateLimit)).fetch }).fetchMetrics(T, ["1"]),
    Retryable,
  );
});

Deno.test("facebook: getPost cek from.id = Page; parser URL reel", async () => {
  const m = mockFetch(
    on(
      "GET",
      `${G}/555555555`,
      () => jsonRes(200, { ...video, id: "555555555", from: { id: "123", name: "Page lain" } }),
    ),
  );
  await assert.rejects(
    createFacebook({ ...cfg, fetch: m.fetch }).getPost(T, "https://www.facebook.com/reel/555555555"),
    (e) => e instanceof AdapterError && e.code === "not_owner",
  );
  assert.equal(fbVideoIdFrom("https://www.facebook.com/ClipperPage/videos/1234567890123456/"), "1234567890123456");
  assert.equal(fbVideoIdFrom("https://www.facebook.com/watch/?v=1234567890123456"), "1234567890123456");
  assert.equal(fbVideoIdFrom("https://evil.com/reel/1234567890123456"), null);
});
