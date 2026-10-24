import assert from "node:assert/strict";
import { jsonRes, mockFetch, on } from "../testing.ts";
import { channelQuery, createYouTube, isoDuration, videoIdFrom } from "./youtube.ts";
import { AdapterError, isMetrics, Retryable, type StoredToken, TokenExpired } from "./types.ts";
import quota from "./testdata/yt_quota.json" with { type: "json" };
import auth from "./testdata/yt_auth.json" with { type: "json" };
import channels from "./testdata/yt_channels_mine.json" with { type: "json" };
import basic from "./testdata/yt_analytics_basic.json" with { type: "json" };
import country from "./testdata/yt_analytics_country.json" with { type: "json" };
import traffic from "./testdata/yt_analytics_traffic.json" with { type: "json" };

const CH = "UCclipperSatu00000000000";
const T: StoredToken = {
  v: 1,
  access_token: "ya29.x",
  refresh_token: "1//r",
  meta: { channel_id: CH, uploads: "UUclipperSatu00000000000" },
};
const cfg = { clientId: "gid", clientSecret: "gsecret" };

const video = (id: string, over: Record<string, unknown> = {}) => ({
  kind: "youtube#video",
  id,
  snippet: {
    publishedAt: "2026-10-01T10:00:00Z",
    channelId: CH,
    title: `Clip ${id} #mplid`,
    description: "@studiosatu",
  },
  contentDetails: { duration: "PT45S" },
  statistics: { viewCount: "1523", likeCount: "88", favoriteCount: "0", commentCount: "7" },
  status: { privacyStatus: "public", uploadStatus: "processed" },
  ...over,
});
const id11 = (i: number) => `vid${String(i).padStart(8, "0")}`;

Deno.test("youtube: videos.list dibatch 50 id per panggilan; id hilang = gone; private = gone", async () => {
  const ids = Array.from({ length: 120 }, (_, i) => id11(i));
  const m = mockFetch(on("GET", "youtube.googleapis.com/youtube/v3/videos", (c) => {
    const req = c.url.searchParams.get("id")!.split(",");
    const items = req.filter((id) => id !== id11(7)).map((id) =>
      id === id11(8) ? video(id, { status: { privacyStatus: "private" } }) : video(id)
    );
    return jsonRes(200, { kind: "youtube#videoListResponse", items, pageInfo: { totalResults: items.length } });
  }));
  const r = await createYouTube({ ...cfg, fetch: m.fetch }).fetchMetrics(T, ids);
  assert.deepEqual(m.calls.map((c) => c.url.searchParams.get("id")!.split(",").length), [50, 50, 20]);
  assert.ok(m.calls.every((c) => c.headers.get("authorization") === "Bearer ya29.x"));
  assert.equal(r.length, 120);
  assert.deepEqual(r[7], { postId: id11(7), gone: true, reason: "not_found" });
  assert.deepEqual(r[8], { postId: id11(8), gone: true, reason: "private" });
  const ok = r[0];
  assert.ok(isMetrics(ok));
  assert.deepEqual([ok.views, ok.likes, ok.comments, ok.shares], [1523, 88, 7, null]);
});

Deno.test("youtube: snapshot final mengambil Analytics (durasi tonton, negara, sumber traffic)", async () => {
  const m = mockFetch(
    on("GET", "youtube.googleapis.com/youtube/v3/videos", () => jsonRes(200, { items: [video(id11(1))] })),
    on("GET", "youtubeanalytics.googleapis.com/v2/reports", (c) => {
      assert.equal(c.url.searchParams.get("ids"), "channel==MINE");
      assert.equal(c.url.searchParams.get("filters"), `video==${id11(1)}`);
      assert.equal(c.url.searchParams.get("startDate"), "2026-10-01");
      const dim = c.url.searchParams.get("dimensions");
      return jsonRes(200, dim === "country" ? country : dim === "insightTrafficSourceType" ? traffic : basic);
    }),
  );
  const [r] = await createYouTube({ ...cfg, fetch: m.fetch }).fetchMetrics(T, [id11(1)], { final: true });
  assert.ok(isMetrics(r));
  assert.equal(r.shares, 12);
  assert.equal(r.extra.avg_watch_time, 21);
  assert.deepEqual(r.extra.countries, { ID: 1300, MY: 150, US: 50 });
  assert.deepEqual(r.extra.traffic_sources, { SHORTS: 1400, YT_SEARCH: 100 });
});

Deno.test("youtube: quotaExceeded → Retryable; 401 → TokenExpired", async () => {
  const q = mockFetch(() => jsonRes(403, quota));
  await assert.rejects(createYouTube({ ...cfg, fetch: q.fetch }).fetchMetrics(T, ["a"]), Retryable);
  const a = mockFetch(() => jsonRes(401, auth));
  await assert.rejects(createYouTube({ ...cfg, fetch: a.fetch }).fetchMetrics(T, ["a"]), TokenExpired);
});

Deno.test("youtube: profile + getPost cek channelId (kepemilikan)", async () => {
  const m = mockFetch(
    on("GET", "youtube.googleapis.com/youtube/v3/channels", () => jsonRes(200, channels)),
    on("GET", "youtube.googleapis.com/youtube/v3/videos", (c) => {
      const id = c.url.searchParams.get("id")!;
      return jsonRes(200, {
        items: [
          video(
            id,
            id === "otherChan01" ? { snippet: { channelId: "UCother", publishedAt: "2026-10-01T10:00:00Z" } } : {},
          ),
        ],
      });
    }),
  );
  const yt = createYouTube({ ...cfg, fetch: m.fetch });
  const p = await yt.profile(T);
  assert.deepEqual([p.externalId, p.handle, p.followers, p.createdAt], [
    CH,
    "clippersatu",
    3400,
    "2021-03-04T05:06:07Z",
  ]);
  assert.equal(p.tokenMeta?.uploads, "UUclipperSatu00000000000");
  const v = await yt.getPost(T, "https://youtube.com/shorts/abcdefghijk?feature=share");
  assert.deepEqual([v.postId, v.durationSec], ["abcdefghijk", 45]);
  await assert.rejects(
    yt.getPost(T, "https://youtu.be/otherChan01"),
    (e) => e instanceof AdapterError && e.code === "not_owner",
  );
});

Deno.test("youtube: refresh mempertahankan refresh_token lama; invalid_grant → TokenExpired", async () => {
  const ok = mockFetch(
    on(
      "POST",
      "oauth2.googleapis.com/token",
      () => jsonRes(200, { access_token: "ya29.new", expires_in: 3599, token_type: "Bearer" }),
    ),
  );
  const t = await createYouTube({ ...cfg, fetch: ok.fetch }).refreshToken(T);
  assert.deepEqual([t.access_token, t.refresh_token, t.meta?.channel_id], ["ya29.new", "1//r", CH]);
  const bad = mockFetch(() =>
    jsonRes(400, { error: "invalid_grant", error_description: "Token has been expired or revoked." })
  );
  await assert.rejects(createYouTube({ ...cfg, fetch: bad.fetch }).refreshToken(T), TokenExpired);
});

Deno.test("youtube: parser URL & durasi", () => {
  assert.equal(videoIdFrom("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"), "dQw4w9WgXcQ");
  assert.equal(videoIdFrom("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ");
  assert.equal(videoIdFrom("https://evil.com/shorts/dQw4w9WgXcQ"), null);
  assert.equal(isoDuration("PT1M3S"), 63);
  assert.equal(isoDuration("P0D"), 0);
});

Deno.test("youtube: mode api_key (fallback D-11) pakai ?key= tanpa Bearer, profile by id, tanpa Analytics/refresh", async () => {
  const K: StoredToken = { v: 1, access_token: "", meta: { ...T.meta!, mode: "api_key" } };
  const m = mockFetch(
    on("GET", "youtube.googleapis.com/youtube/v3/channels", () => jsonRes(200, channels)),
    on(
      "GET",
      "youtube.googleapis.com/youtube/v3/videos",
      (c) => jsonRes(200, { items: [video(c.url.searchParams.get("id")!)] }),
    ),
  );
  const yt = createYouTube({ ...cfg, apiKey: "AIzaKEY", fetch: m.fetch });
  assert.equal((await yt.profile(K)).externalId, CH);
  const [r] = await yt.fetchMetrics(K, ["abcdefghijk"], { final: true });
  assert.ok(isMetrics(r) && r.views === 1523 && !("analytics_error" in r.extra!));
  assert.equal(await yt.refreshToken(K), K);
  assert.ok(m.calls.every((c) => c.url.searchParams.get("key") === "AIzaKEY" && !c.headers.has("authorization")));
  assert.equal(m.calls[0].url.searchParams.get("id"), CH);
  assert.ok(!m.calls.some((c) => c.url.hostname.startsWith("youtubeanalytics")));
  const ch = await yt.channel!("https://www.youtube.com/@clippersatu/shorts");
  assert.equal(ch.externalId, CH);
  assert.equal(m.calls.at(-1)!.url.searchParams.get("forHandle"), "@clippersatu");
  await assert.rejects(
    createYouTube({ ...cfg, fetch: m.fetch }).profile(K),
    (e) => e instanceof AdapterError && e.code === "fallback_unavailable",
  );
});

Deno.test("youtube: parser channel (@handle, /@handle, /channel/UC…, UC…)", () => {
  const uc = "UCclipperSatu00000000000";
  assert.deepEqual(channelQuery("@clipper.satu"), { forHandle: "@clipper.satu" });
  assert.deepEqual(channelQuery("youtube.com/@clippersatu?si=x"), { forHandle: "@clippersatu" });
  assert.deepEqual(channelQuery(`https://m.youtube.com/channel/${uc}/videos`), { id: uc });
  assert.deepEqual(channelQuery(uc), { id: uc });
  for (const bad of ["clippersatu", "https://evil.test/@x", "https://youtube.com/watch?v=abcdefghijk", "@a"]) {
    assert.equal(channelQuery(bad), null, bad);
  }
});
