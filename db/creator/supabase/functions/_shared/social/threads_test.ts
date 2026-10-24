import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { createThreads, THREADS } from "./threads.ts";
import { AdapterError, isMetrics, type StoredToken, TokenExpired } from "./types.ts";
import insights from "./testdata/threads_insights.json" with { type: "json" };
import expired from "./testdata/graph_token_expired.json" with { type: "json" };
import missing from "./testdata/graph_object_missing.json" with { type: "json" };

const G = `graph.threads.com/${THREADS.version}`;
const T: StoredToken = { v: 1, access_token: "THQ.x", meta: { threads_user_id: "1001", username: "clippersatu" } };
const cfg = { appId: "th-app", appSecret: "th-secret" };

Deno.test("threads: exchangeCode → th_exchange_token; profile + followers_count (total_value)", async () => {
  const m = mockFetch(
    on("POST", "graph.threads.com/oauth/access_token", () => jsonRes(200, { access_token: "short", user_id: 1001 })),
    on("GET", "graph.threads.com/access_token", (c) => {
      assert.equal(c.url.searchParams.get("grant_type"), "th_exchange_token");
      return jsonRes(200, { access_token: "long", token_type: "bearer", expires_in: 5183944 });
    }),
    on("GET", `${G}/me`, () => jsonRes(200, { id: "1001", username: "clippersatu", name: "Clipper" })),
    on(
      "GET",
      `${G}/me/threads_insights`,
      () => jsonRes(200, { data: [{ name: "followers_count", period: "day", total_value: { value: 777 } }] }),
    ),
  );
  const a = createThreads({ ...cfg, fetch: m.fetch });
  const t = await a.exchangeCode("c", "https://app.test/cb");
  assert.equal(t.access_token, "long");
  const p = await a.profile(t);
  assert.deepEqual([p.externalId, p.handle, p.followers], ["1001", "clippersatu", 777]);
});

Deno.test("threads: fetchMetrics views/likes/replies/shares (+reposts, quotes di extra)", async () => {
  const m = mockFetch(
    on(
      "GET",
      `${G}/18050206876707110`,
      () =>
        jsonRes(200, {
          id: "18050206876707110",
          text: "Clip #mplid",
          media_type: "VIDEO",
          timestamp: "2026-10-01T10:00:00+0000",
        }),
    ),
    on("GET", `${G}/18050206876707110/insights`, (c) => {
      assert.equal(c.url.searchParams.get("metric"), "views,likes,replies,reposts,quotes,shares");
      return jsonRes(200, insights);
    }),
  );
  const [r] = await createThreads({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ["18050206876707110"]);
  assert.ok(isMetrics(r));
  assert.deepEqual([r.views, r.likes, r.comments, r.shares, r.extra.reposts, r.extra.quotes], [1200, 80, 7, 5, 3, 1]);
});

Deno.test("threads: gone & token expired", async () => {
  const gone = mockFetch(() => jsonRes(400, missing));
  assert.equal(
    ((await createThreads({ ...cfg, fetch: gone.fetch }).fetchMetrics(T, ["9"]))[0] as { gone?: boolean }).gone,
    true,
  );
  const exp = mockFetch(() => jsonRes(400, expired));
  await assert.rejects(createThreads({ ...cfg, fetch: exp.fetch }).fetchMetrics(T, ["9"]), TokenExpired);
});

Deno.test("threads: getPost id milik akun lain = not_owner", async () => {
  const m = mockFetch(
    on("GET", `${G}/18050206876707999`, () =>
      jsonRes(200, {
        id: "18050206876707999",
        media_type: "VIDEO",
        username: "orang_lain",
        timestamp: "2026-10-01T10:00:00+0000",
      })),
  );
  await assert.rejects(
    createThreads({ ...cfg, fetch: m.fetch }).getPost(T, "18050206876707999"),
    (e) => e instanceof AdapterError && e.code === "not_owner",
  );
});
