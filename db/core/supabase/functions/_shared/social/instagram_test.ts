import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { createInstagram, INSTAGRAM, shortcodeFrom } from "./instagram.ts";
import { AdapterError, isMetrics, Retryable, type StoredToken, TokenExpired } from "./types.ts";
import business from "./testdata/ig_me_business.json" with { type: "json" };
import personal from "./testdata/ig_me_personal.json" with { type: "json" };
import reel from "./testdata/ig_media_reel.json" with { type: "json" };
import insights from "./testdata/ig_insights_reel.json" with { type: "json" };
import expired from "./testdata/graph_token_expired.json" with { type: "json" };
import missing from "./testdata/graph_object_missing.json" with { type: "json" };
import rateLimit from "./testdata/graph_rate_limit.json" with { type: "json" };

const V = INSTAGRAM.version;
const T: StoredToken = { v: 1, access_token: "IGAA.x", meta: { ig_user_id: "17841400000000001", username: "clippersatu" } };
const cfg = { appId: "ig-app", appSecret: "ig-secret" };

Deno.test("instagram: exchangeCode → long-lived token; profile Creator diterima", async () => {
  const m = mockFetch(
    on("POST", "api.instagram.com/oauth/access_token", () =>
      jsonRes(200, { data: [{ access_token: "short", user_id: "17841400000000001", permissions: "instagram_business_basic,instagram_business_manage_insights" }] })),
    on("GET", "graph.instagram.com/access_token", (c) => {
      assert.equal(c.url.searchParams.get("grant_type"), "ig_exchange_token");
      assert.equal(c.url.searchParams.get("access_token"), "short");
      return jsonRes(200, { access_token: "long", token_type: "bearer", expires_in: 5183944 });
    }),
    on("GET", `graph.instagram.com/${V}/me`, () => jsonRes(200, business)),
  );
  const a = createInstagram({ ...cfg, fetch: m.fetch });
  const t = await a.exchangeCode("c", "https://app.test/cb");
  assert.equal(t.access_token, "long");
  const p = await a.profile(t);
  assert.deepEqual([p.externalId, p.handle, p.followers, p.accountType], ["17841400000000001", "clippersatu", 2300, "MEDIA_CREATOR"]);
});

Deno.test("instagram: akun personal ditolak dengan kode ig_personal", async () => {
  const m = mockFetch(on("GET", `graph.instagram.com/${V}/me`, () => jsonRes(200, personal)));
  await assert.rejects(createInstagram({ ...cfg, fetch: m.fetch }).profile(T), (e) => e instanceof AdapterError && e.code === "ig_personal");
});

Deno.test("instagram: fetchMetrics memakai metrik views (bukan plays) + extra reach/watch time/skip rate", async () => {
  const m = mockFetch(
    on("GET", `graph.instagram.com/${V}/17895695668004550`, () => jsonRes(200, reel)),
    on("GET", `graph.instagram.com/${V}/17895695668004550/insights`, (c) => {
      const metric = c.url.searchParams.get("metric")!.split(",");
      assert.ok(metric.includes("views") && !metric.includes("plays") && !metric.includes("impressions"));
      return jsonRes(200, insights);
    }),
  );
  const [r] = await createInstagram({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ["17895695668004550"]);
  assert.ok(isMetrics(r));
  assert.deepEqual([r.views, r.likes, r.comments, r.shares], [5321, 121, 9, 14]);
  assert.equal(r.caption, "Clip seru #mplid @studiosatu");
  assert.deepEqual([r.extra.reach, r.extra.avg_watch_time, r.extra.skip_rate], [4100, 7310, 41]);
});

Deno.test("instagram: media dihapus (100/33) = gone; 190 = TokenExpired; code 4 = Retryable", async () => {
  const gone = mockFetch(on("GET", `graph.instagram.com/${V}/17895695668004551`, () => jsonRes(400, missing)));
  assert.deepEqual((await createInstagram({ ...cfg, fetch: gone.fetch }).fetchMetrics(T, ["17895695668004551"]))[0], {
    postId: "17895695668004551",
    gone: true,
    reason: missing.error.message,
  });
  const exp = mockFetch(() => jsonRes(400, expired));
  await assert.rejects(createInstagram({ ...cfg, fetch: exp.fetch }).fetchMetrics(T, ["1"]), TokenExpired);
  const lim = mockFetch(() => jsonRes(400, rateLimit));
  await assert.rejects(createInstagram({ ...cfg, fetch: lim.fetch }).fetchMetrics(T, ["1"]), Retryable);
});

Deno.test("instagram: getPost dari link reel dicari di media milik akun; tidak ada = not_owner", async () => {
  const page = { data: [{ ...reel, shortcode: "DAbc123xyz_", permalink: "https://www.instagram.com/reel/DAbc123xyz_/" }] };
  const m = mockFetch(on("GET", `graph.instagram.com/${V}/me/media`, () => jsonRes(200, page)));
  const a = createInstagram({ ...cfg, fetch: m.fetch });
  const v = await a.getPost(T, "https://www.instagram.com/reel/DAbc123xyz_/?igsh=abc");
  assert.deepEqual([v.postId, v.durationSec, v.postedAt], ["17895695668004550", null, "2026-10-01T10:00:00.000Z"]);
  await assert.rejects(a.getPost(T, "https://www.instagram.com/reel/ZZZ/"), (e) => e instanceof AdapterError && e.code === "not_owner");
  assert.equal(shortcodeFrom("https://www.instagram.com/p/Cx9_-a/"), "Cx9_-a");
});
