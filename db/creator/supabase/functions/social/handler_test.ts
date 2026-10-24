import assert from "node:assert/strict";
import type { User } from "../_shared/auth.ts";
import { RpcError } from "../_shared/db.ts";
import { HttpError } from "../_shared/http.ts";
import {
  AdapterError,
  type PlatformAdapter,
  type StoredToken,
  TokenExpired,
  type Video,
} from "../_shared/social/mod.ts";
import { fakeRpc } from "../_shared/testing.ts";
import {
  type AccountRow,
  createSocialHandler,
  mapRpcError,
  type SocialDeps,
  SUBMIT_ERRORS,
  youtubeCode,
} from "./handler.ts";

const USER: User = {
  id: "11111111-1111-4111-8111-111111111111",
  roles: ["clipper"],
  aal: "aal1",
  kyc: null,
  jwt: "jwt",
  claims: {},
};
const ACCOUNT = "22222222-2222-4222-8222-222222222222";
const CLAIM = "33333333-3333-4333-8333-333333333333";
const ORIGIN = "https://app.clipper.test";
const CB = "https://app.clipper.test/api/oauth/tiktok/callback";

const VIDEO: Video = {
  postId: "7080",
  url: "https://www.tiktok.com/@c/video/7080",
  caption: "#mplid",
  postedAt: "2026-10-01T10:00:00.000Z",
  durationSec: 34,
  thumbnail: null,
};
const tokenJson = JSON.stringify({ v: 1, access_token: "at", expires_at: "2099-01-01T00:00:00Z" });

function adapter(over: Partial<PlatformAdapter> = {}): PlatformAdapter {
  return {
    platform: "tiktok",
    pkce: "none",
    maxBatch: 20,
    authorizeUrl: (r: string, s: string, c?: string) => `https://auth.test/?r=${r}&s=${s}&c=${c ?? ""}`,
    exchangeCode: () => Promise.resolve({ v: 1, access_token: "at", meta: { open_id: "o1" } } as StoredToken),
    profile: () =>
      Promise.resolve({
        externalId: "o1",
        handle: "clipper",
        followers: 10,
        createdAt: null,
        tokenMeta: { username: "clipper" },
      }),
    listVideos: () => Promise.resolve([VIDEO, { ...VIDEO, postId: "7081", caption: "tanpa tag" }]),
    getPost: () => Promise.resolve(VIDEO),
    fetchMetrics: () => Promise.resolve([]),
    refreshToken: (t: StoredToken) => Promise.resolve(t),
    ...over,
  } as PlatformAdapter;
}

const acct = (over: Partial<AccountRow> = {}): AccountRow => ({
  id: ACCOUNT,
  user_id: USER.id,
  platform: "tiktok",
  external_id: "o1",
  handle: "clipper",
  status: "verified",
  token: tokenJson,
  ...over,
});

function deps(
  rpcHandlers: Record<string, (a: Record<string, unknown>) => unknown> = {},
  over: Partial<SocialDeps> = {},
) {
  const f = fakeRpc({
    worker_account_token: () => acct(),
    worker_account_status: () => null,
    store_social_token: () => "sid",
    ...rpcHandlers,
  });
  const d: SocialDeps = {
    auth: (req) =>
      req.headers.get("authorization") === "Bearer good"
        ? Promise.resolve(USER)
        : Promise.reject(new HttpError(401, "unauthorized")),
    rpc: f.rpc,
    adapter: () => adapter(),
    flags: () => Promise.resolve({ tiktok: true, instagram: true, x: true, youtube: true, threads: false }),
    getClaim: () =>
      Promise.resolve({
        id: CLAIM,
        campaign_id: "camp",
        user_id: USER.id,
        status: "open",
        created_at: "2026-09-30T00:00:00Z",
      }),
    missingTags: (_u, _c, caption) => Promise.resolve(caption.includes("#mplid") ? [] : ["#mplid"]),
    coverHash: () => Promise.resolve("4242"),
    redirectAllowlist: [CB],
    origins: [ORIGIN],
    ...over,
  };
  return { handler: createSocialHandler(d), calls: f.calls };
}

const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://core.test/functions/v1/social", {
    method: "POST",
    headers: { authorization: "Bearer good", origin: ORIGIN, "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });

const rpcErr = (message: string, code = "P0001") => () => {
  throw new RpcError("worker_create_submission", code, message);
};

Deno.test("social: submit sukses → getPost (kepemilikan) → worker_create_submission", async () => {
  const { handler, calls } = deps({ worker_create_submission: () => ({ submission_id: "sub1", status: "in_review" }) });
  const res = await handler(post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, url: VIDEO.url }));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("access-control-allow-origin"), ORIGIN);
  assert.deepEqual(await res.json(), { submission_id: "sub1", status: "in_review" });
  assert.deepEqual(calls.find((c) => c.fn === "worker_create_submission")!.args, {
    p_user: USER.id,
    p_claim: CLAIM,
    p_account: ACCOUNT,
    p_post_id: "7080",
    p_url: VIDEO.url,
    p_posted_at: VIDEO.postedAt,
    p_caption: "#mplid",
    p_duration_sec: 34,
    p_cover_hash: "4242",
  });
});

Deno.test("social: submit memetakan error SQL ke kode (missing_tags dirinci per tag)", async () => {
  const cases: [string, string, unknown][] = [
    ["missing_tags:#mplid,@studiosatu", "missing_tags", ["#mplid", "@studiosatu"]],
    ["missing_tags:{#mplid,https://studio.id/promo}", "missing_tags", ["#mplid", "https://studio.id/promo"]],
    ["already_submitted", "already_submitted", undefined],
    ["posted_before_claim", "posted_before_claim", undefined],
    ["duration_out_of_range:12", "duration_out_of_range", "12"],
    ["reused_video", "reused_video", undefined],
    ["claim_not_open", "claim_not_open", undefined],
    ["account_inactive", "account_inactive", undefined],
    ["invalid:url", "invalid", "url"],
    ["not_eligible:min_followers", "not_eligible:min_followers", undefined],
    ["not_eligible:min_account_age", "not_eligible:min_account_age", undefined],
    ["not_eligible:max_clips", "not_eligible:max_clips", undefined],
  ];
  for (const [msg, code, detail] of cases) {
    const { handler } = deps({ worker_create_submission: rpcErr(msg) });
    const res = await handler(post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, post_id: "7080" }));
    assert.equal(res.status, 422, msg);
    const body = await res.json();
    assert.equal(body.error, code);
    assert.deepEqual(body.detail, detail);
  }
  // error tak dikenal tidak bocor
  const { handler } = deps({ worker_create_submission: rpcErr("relation tracking.x does not exist", "42P01") });
  const res = await handler(post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, post_id: "7080" }));
  assert.equal(res.status, 500);
  assert.equal((await res.json()).error, "internal");
  assert.equal(SUBMIT_ERRORS.length, 14);
});

Deno.test("social: submit video akun lain → not_owner; akun bukan milik user → account_not_yours; token mati → 409 + status expired", async () => {
  let r = await deps({}, {
    adapter: () => adapter({ getPost: () => Promise.reject(new AdapterError("not_owner", "bukan milikmu")) }),
  })
    .handler(post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, post_id: "1" }));
  assert.deepEqual([r.status, (await r.json()).error], [422, "not_owner"]);

  r = await deps({ worker_account_token: () => acct({ user_id: "someone-else" }) }).handler(
    post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, post_id: "1" }),
  );
  assert.deepEqual([r.status, (await r.json()).error], [422, "account_not_yours"]);

  const d = deps({}, { adapter: () => adapter({ getPost: () => Promise.reject(new TokenExpired("401")) }) });
  r = await d.handler(post({ action: "submit", claim_id: CLAIM, account_id: ACCOUNT, post_id: "1" }));
  assert.deepEqual([r.status, (await r.json()).error], [409, "token_expired"]);
  assert.deepEqual(d.calls.find((c) => c.fn === "worker_account_status")!.args, {
    p_account: ACCOUNT,
    p_status: "expired",
  });

  r = await deps().handler(post({ action: "submit", claim_id: "bukan-uuid", account_id: ACCOUNT, post_id: "1" }));
  assert.deepEqual([r.status, (await r.json()).error], [400, "bad_request"]);
});

Deno.test("social: connect memetakan ig_personal, social_taken, account_limit, platform_disabled", async () => {
  const body = { action: "connect", platform: "instagram", code: "c", redirect_uri: CB };
  let r = await deps({}, { adapter: () => adapter({ profile: () => Promise.reject(new AdapterError("ig_personal")) }) })
    .handler(post(body));
  assert.deepEqual([r.status, (await r.json()).error], [422, "ig_personal"]);

  r = await deps({ worker_upsert_social_account: rpcErr("social_taken") }).handler(post(body));
  assert.deepEqual([r.status, (await r.json()).error], [422, "social_taken"]);

  r = await deps({ worker_upsert_social_account: rpcErr("maksimal 3 akun instagram per clipper", "23514") }).handler(
    post(body),
  );
  assert.deepEqual([r.status, (await r.json()).error], [422, "account_limit"]);

  r = await deps().handler(post({ ...body, platform: "threads" }));
  assert.deepEqual([r.status, (await r.json()).error], [422, "platform_disabled"]);

  r = await deps({}, {
    adapter: () => adapter({ exchangeCode: () => Promise.reject(new AdapterError("oauth_failed")) }),
  }).handler(post(body));
  assert.deepEqual([r.status, (await r.json()).error], [422, "oauth_failed"]);
});

Deno.test("social: connect sukses menyimpan token + meta profil lewat worker_upsert_social_account", async () => {
  const d = deps({ worker_upsert_social_account: () => ACCOUNT });
  const r = await d.handler(post({ action: "connect", platform: "tiktok", code: "c", redirect_uri: CB }));
  assert.deepEqual(await r.json(), { account_id: ACCOUNT, platform: "tiktok", handle: "clipper", followers: 10 });
  const args = d.calls.find((c) => c.fn === "worker_upsert_social_account")!.args;
  assert.deepEqual(JSON.parse(args.p_token as string).meta, { open_id: "o1", username: "clipper" });
  assert.equal(args.p_user, USER.id);
});

Deno.test("social: authorize cek allowlist redirect, PKCE untuk X", async () => {
  let r = await deps().handler(post({ action: "authorize", platform: "tiktok", redirect_uri: "https://evil.test/cb" }));
  assert.deepEqual([r.status, (await r.json()).error], [400, "redirect_not_allowed"]);
  r = await deps().handler(post({ action: "authorize", platform: "tiktok", redirect_uri: CB }));
  const plain = await r.json();
  assert.ok(plain.state && !plain.code_verifier);
  r = await deps({}, { adapter: () => adapter({ pkce: "required" }) }).handler(
    post({ action: "authorize", platform: "x", redirect_uri: CB }),
  );
  const pk = await r.json();
  assert.match(pk.code_verifier, /^[A-Za-z0-9_-]{43,128}$/);
  assert.ok(new URL(pk.url).searchParams.get("c"));
});

Deno.test("social: list_videos menandai tag yang kurang per video", async () => {
  const r = await deps().handler(post({ action: "list_videos", claim_id: CLAIM, account_id: ACCOUNT }));
  const body = await r.json();
  assert.deepEqual(body.videos.map((v: { postId: string; missing_tags: string[] }) => [v.postId, v.missing_tags]), [[
    "7080",
    [],
  ], ["7081", ["#mplid"]]]);
});

Deno.test("social: CORS hanya APP_ORIGINS; tanpa JWT → 401", async () => {
  const d = deps();
  let r = await d.handler(
    new Request("https://core.test/functions/v1/social", { method: "OPTIONS", headers: { origin: ORIGIN } }),
  );
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
  r = await d.handler(
    new Request("https://core.test/functions/v1/social", {
      method: "OPTIONS",
      headers: { origin: "https://evil.test" },
    }),
  );
  assert.equal(r.status, 403);
  r = await d.handler(post({ action: "submit" }, { origin: "https://evil.test" }));
  assert.equal(r.status, 403);
  r = await d.handler(post({ action: "submit" }, { authorization: "Bearer bad" }));
  assert.equal(r.status, 401);
  r = await d.handler(post({ action: "__proto__" }));
  assert.deepEqual([r.status, (await r.json()).error], [400, "bad_action"]);
});

Deno.test("social: mapRpcError hanya meneruskan kode yang dikenal", () => {
  const e = mapRpcError(new RpcError("f", "P0001", "profile_inactive"), SUBMIT_ERRORS);
  assert.deepEqual([e.status, e.code], [422, "profile_inactive"]);
  assert.equal(mapRpcError(new RpcError("f", "P0001", "secret_internal_state"), SUBMIT_ERRORS).code, "internal");
});

Deno.test("social: youtube_code → youtube_verify (kode di deskripsi) simpan akun token mode api_key", async () => {
  const UC = "UCclipperSatu00000000000";
  const code = await youtubeCode(USER.id, UC);
  assert.match(code, /^CLIP-[0-9A-F]{10}$/);
  assert.notEqual(code, await youtubeCode("44444444-4444-4444-8444-444444444444", UC));
  let description = "channel klip";
  const yt = adapter({
    platform: "youtube",
    channel: (ref: string) =>
      Promise.resolve({
        externalId: UC,
        handle: ref.replace(/^@/, ""),
        followers: null,
        createdAt: "2021-03-04T05:06:07Z",
        tokenMeta: { channel_id: UC, uploads: "UUclipperSatu00000000000" },
        description,
      }),
  });
  const { handler, calls } = deps({ worker_upsert_social_account: () => ACCOUNT }, { adapter: () => yt });
  const res = await handler(post({ action: "youtube_code", channel: "@clippersatu" }));
  assert.deepEqual(await res.json(), { channel_id: UC, handle: "clippersatu", code });

  const miss = await handler(post({ action: "youtube_verify", channel: "@clippersatu" }));
  assert.equal(miss.status, 422);
  assert.equal((await miss.json()).error, "code_not_found");
  assert.ok(!calls.some((c) => c.fn === "worker_upsert_social_account"));

  description = `channel klip ${code}`;
  const ok = await handler(post({ action: "youtube_verify", channel: "@clippersatu" }));
  assert.equal(ok.status, 200);
  const args = calls.find((c) => c.fn === "worker_upsert_social_account")!.args;
  assert.deepEqual([args.p_user, args.p_platform, args.p_external_id, args.p_followers], [
    USER.id,
    "youtube",
    UC,
    null,
  ]);
  const tok = JSON.parse(args.p_token as string);
  assert.deepEqual([tok.access_token, tok.expires_at, tok.meta], ["", null, {
    channel_id: UC,
    uploads: "UUclipperSatu00000000000",
    mode: "api_key",
  }]);
});

Deno.test("social: youtube_verify ditolak saat platform mati atau adapter tanpa fallback", async () => {
  const off = deps({}, { flags: () => Promise.resolve({ youtube: false }) });
  assert.equal(
    (await (await off.handler(post({ action: "youtube_verify", channel: "@x12" }))).json()).error,
    "platform_disabled",
  );
  const noFb = deps({}, { adapter: () => adapter({ platform: "youtube" }) });
  assert.equal(
    (await (await noFb.handler(post({ action: "youtube_code", channel: "@x12" }))).json()).error,
    "fallback_unavailable",
  );
});
