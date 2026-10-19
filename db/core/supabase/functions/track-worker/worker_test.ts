import assert from "node:assert/strict";
import { RpcError } from "../_shared/db.ts";
import { fakeRpc } from "../_shared/testing.ts";
import {
  type FetchOptions,
  type MetricResult,
  type Platform,
  type PlatformAdapter,
  Retryable,
  type StoredToken,
  TokenExpired,
} from "../_shared/social/mod.ts";
import { runTrackWorker, type SubmissionContext, xDue } from "./worker.ts";

const H = 3_600_000;
const NOW = Date.parse("2026-10-19T12:00:00Z");
const tok = (exp = NOW + 10 * H) =>
  JSON.stringify({ v: 1, access_token: "at", refresh_token: "rt", expires_at: new Date(exp).toISOString() });

function ctx(
  id: string,
  platform: Platform,
  account: string,
  over: Partial<SubmissionContext> = {},
  sub: Record<string, unknown> = {},
): SubmissionContext {
  return {
    submission: {
      id,
      platform,
      post_id: `post-${id}`,
      url: `https://x/${id}`,
      posted_at: new Date(NOW - 30 * H).toISOString(),
      status: "tracking",
      user_id: "u1",
      campaign_id: "c1",
      counted_views: 0,
      ...sub,
    } as SubmissionContext["submission"],
    account: { id: account, external_id: "e", handle: "h", status: "verified" },
    token: tok(),
    campaign: {},
    final: false,
    ...over,
  };
}

function fakeAdapter(
  platform: Platform,
  impl: (ids: string[], opts?: FetchOptions) => MetricResult[] | Promise<MetricResult[]>,
  extra: Partial<PlatformAdapter> = {},
) {
  const calls: { ids: string[]; opts?: FetchOptions }[] = [];
  const a = {
    platform,
    pkce: "none",
    maxBatch: 20,
    fetchMetrics: (_t: StoredToken, ids: string[], opts?: FetchOptions) => {
      calls.push({ ids, opts });
      return Promise.resolve(impl(ids, opts));
    },
    refreshToken: (t: StoredToken) =>
      Promise.resolve({ ...t, access_token: "fresh", expires_at: new Date(NOW + 24 * H).toISOString() }),
    ...extra,
  } as unknown as PlatformAdapter;
  return { a, calls };
}

const metrics = (postId: string, views = 1000): MetricResult => ({
  postId,
  views,
  likes: 10,
  comments: 2,
  shares: 1,
  caption: "#mplid",
  extra: { reach: 900 },
  raw: { id: postId },
});

function setup(
  messages: { msg_id: number; message: { submission_id: string; platform: string } }[],
  contexts: Record<string, SubmissionContext | null>,
) {
  let dequeues = 0;
  return fakeRpc({
    worker_dequeue: () => (dequeues++ === 0 ? messages : []),
    worker_submission_context: (a) => contexts[a.p_submission as string] ?? null,
    worker_record_snapshot: () => ({ snapshot_id: 1, flagged: false, next_poll_at: null, locked: false }),
    worker_post_gone: () => null,
    worker_account_status: () => null,
    worker_ack: () => true,
    store_social_token: () => "secret-id",
  });
}

Deno.test("track-worker: dequeue → snapshot/gone → ack; Retryable tidak di-ack", async () => {
  const msgs = [
    { msg_id: 1, message: { submission_id: "s1", platform: "tiktok" } },
    { msg_id: 2, message: { submission_id: "s2", platform: "tiktok" } },
    { msg_id: 3, message: { submission_id: "s3", platform: "youtube" } },
  ];
  const f = setup(msgs, {
    s1: ctx("s1", "tiktok", "a1"),
    s2: ctx("s2", "tiktok", "a1"),
    s3: ctx("s3", "youtube", "a2"),
  });
  const tt = fakeAdapter(
    "tiktok",
    (ids) =>
      ids.map((id) =>
        id === "post-s2" ? { postId: id, gone: true as const, reason: "not_found_or_private" } : metrics(id)
      ),
  );
  const yt = fakeAdapter("youtube", () => {
    throw new Retryable("quotaExceeded");
  });
  const s = await runTrackWorker({
    rpc: f.rpc,
    adapter: (p) => (p === "tiktok" ? tt.a : yt.a),
    flags: () => Promise.resolve({ tiktok: true, youtube: true }),
    now: () => NOW,
  });
  // satu panggilan TikTok untuk dua submisi akun yang sama
  assert.deepEqual(tt.calls.map((c) => c.ids.sort()), [["post-s1", "post-s2"]]);
  const snap = f.calls.find((c) => c.fn === "worker_record_snapshot")!;
  assert.deepEqual(snap.args, {
    p_submission: "s1",
    p_views: 1000,
    p_likes: 10,
    p_comments: 2,
    p_shares: 1,
    p_caption: "#mplid",
    p_raw: { id: "post-s1" },
    p_extra: { reach: 900 },
  });
  assert.deepEqual(f.calls.find((c) => c.fn === "worker_post_gone")!.args, {
    p_submission: "s2",
    p_reason: "not_found_or_private",
  });
  const acked = f.calls.filter((c) => c.fn === "worker_ack").map((c) => c.args.p_msg_id).sort();
  assert.deepEqual(acked, [1, 2]); // msg 3 (Retryable) tidak di-ack → kembali setelah visibility timeout
  assert.ok(f.calls.every((c) => c.fn !== "worker_ack" || c.args.p_queue === "tracking"));
  assert.deepEqual([s.recorded, s.gone, s.retried, s.acked], [1, 1, 1, 2]);
  assert.deepEqual(f.calls[0].args, { p_queue: "tracking", p_qty: 20, p_vt_seconds: 300 });
});

Deno.test("track-worker: TokenExpired → account_status expired + ack; tidak pernah menulis 0 views", async () => {
  const f = setup([{ msg_id: 9, message: { submission_id: "s9", platform: "instagram" } }], {
    s9: ctx("s9", "instagram", "a9"),
  });
  const ig = fakeAdapter("instagram", () => {
    throw new TokenExpired("190");
  });
  const s = await runTrackWorker({
    rpc: f.rpc,
    adapter: () => ig.a,
    flags: () => Promise.resolve({ instagram: true }),
    now: () => NOW,
  });
  assert.deepEqual(f.calls.find((c) => c.fn === "worker_account_status")!.args, {
    p_account: "a9",
    p_status: "expired",
  });
  assert.ok(!f.calls.some((c) => c.fn === "worker_record_snapshot"));
  assert.deepEqual([s.expired, s.acked], [1, 1]);
});

Deno.test("track-worker: per-post retry tidak di-ack; platform mati / token pause / submisi basi di-ack tanpa API", async () => {
  const contexts = {
    s1: ctx("s1", "tiktok", "a1"),
    s2: ctx("s2", "threads", "a2"), // flag threads mati
    s3: ctx("s3", "tiktok", "a3", { account: { id: "a3", external_id: "e", handle: "h", status: "token_expired" } }),
    s4: ctx("s4", "tiktok", "a1", {}, { status: "locked" }),
  };
  const msgs = Object.keys(contexts).map((id, i) => ({
    msg_id: i + 1,
    message: { submission_id: id, platform: "tiktok" },
  }));
  msgs.push({ msg_id: 99, message: { submission_id: "s1", platform: "tiktok" } }); // duplikat submisi
  const f = setup(msgs, contexts);
  const tt = fakeAdapter(
    "tiktok",
    (ids) => ids.map((id) => ({ postId: id, retry: true as const, reason: "view_count_missing" })),
  );
  const s = await runTrackWorker({
    rpc: f.rpc,
    adapter: () => tt.a,
    flags: () => Promise.resolve({ tiktok: true, threads: false }),
    now: () => NOW,
  });
  assert.equal(tt.calls.length, 1);
  assert.deepEqual(tt.calls[0].ids, ["post-s1"]);
  const acked = f.calls.filter((c) => c.fn === "worker_ack").map((c) => c.args.p_msg_id).sort();
  assert.deepEqual(acked, [2, 3, 4]);
  assert.deepEqual([s.skipped, s.retried], [3, 1]);
});

Deno.test("track-worker: token hampir kedaluwarsa di-refresh & disimpan sebelum fetch; final diteruskan ke adapter", async () => {
  const c = ctx("s1", "youtube", "a1", { token: tok(NOW + 30_000), final: true });
  const f = setup([{ msg_id: 1, message: { submission_id: "s1", platform: "youtube" } }], { s1: c });
  let used = "";
  const yt = fakeAdapter("youtube", (ids) => ids.map((id) => metrics(id)), {
    fetchMetrics(t: StoredToken, ids: string[], opts?: FetchOptions) {
      used = t.access_token;
      assert.equal(opts?.final, true);
      return Promise.resolve(ids.map((id) => metrics(id)));
    },
  });
  await runTrackWorker({
    rpc: f.rpc,
    adapter: () => yt.a,
    flags: () => Promise.resolve({ youtube: true }),
    now: () => NOW,
  });
  assert.equal(used, "fresh");
  const store = f.calls.find((x) => x.fn === "store_social_token")!;
  assert.equal(store.args.p_account_id, "a1");
  assert.equal(JSON.parse(store.args.p_token as string).access_token, "fresh");
});

Deno.test("track-worker: X hanya di checkpoint 24 jam, 7 hari, lock", () => {
  const at = (ageH: number, over: Partial<SubmissionContext> = {}, last?: number) =>
    xDue(
      ctx("s", "x", "a", over, {
        posted_at: new Date(NOW - ageH * H).toISOString(),
        last_snapshot_at: last ? new Date(NOW - last * H).toISOString() : null,
      }),
      NOW,
    );
  assert.equal(at(4), false);
  assert.equal(at(23), false);
  assert.equal(at(24.5), true);
  assert.equal(at(26), false); // lewat jendela tanpa last_snapshot_at
  assert.equal(at(26, {}, 30), true); // snapshot terakhir sebelum checkpoint 24 jam → masih jatuh tempo
  assert.equal(at(26, {}, 1), false); // checkpoint 24 jam sudah diambil
  assert.equal(at(7 * 24 + 0.5), true);
  assert.equal(at(100), false);
  assert.equal(at(100, { final: true }), true);
});

Deno.test("track-worker: berhenti saat budget habis; flags gagal → run berhenti tanpa ack", async () => {
  let t = NOW;
  const f = setup([{ msg_id: 1, message: { submission_id: "s1", platform: "tiktok" } }], {
    s1: ctx("s1", "tiktok", "a1"),
  });
  const s = await runTrackWorker({
    rpc: f.rpc,
    adapter: () => fakeAdapter("tiktok", () => []).a,
    flags: () => Promise.resolve({}),
    now: () => (t += 60_000),
  });
  assert.equal(s.dequeued, 0);
  const g = setup([{ msg_id: 1, message: { submission_id: "s1", platform: "tiktok" } }], {
    s1: ctx("s1", "tiktok", "a1"),
  });
  await assert.rejects(
    runTrackWorker({
      rpc: g.rpc,
      adapter: () => fakeAdapter("tiktok", () => []).a,
      flags: () => Promise.reject(new Error("db")),
      now: () => NOW,
    }),
  );
  assert.ok(!g.calls.some((c) => c.fn === "worker_ack"));
});

Deno.test("track-worker: submisi sudah dihapus (P0002) → ack; error RPC lain → tidak di-ack", async () => {
  let n = 0;
  const f = fakeRpc({
    worker_dequeue: () => (n++ === 0
      ? [{ msg_id: 1, message: { submission_id: "gone", platform: "tiktok" } }, {
        msg_id: 2,
        message: { submission_id: "flaky", platform: "tiktok" },
      }]
      : []),
    worker_submission_context: (a) => {
      throw new RpcError("worker_submission_context", a.p_submission === "gone" ? "P0002" : "57014", "x");
    },
    worker_ack: () => true,
  });
  const s = await runTrackWorker({
    rpc: f.rpc,
    adapter: () => fakeAdapter("tiktok", () => []).a,
    flags: () => Promise.resolve({ tiktok: true }),
    now: () => NOW,
  });
  assert.deepEqual(f.calls.filter((c) => c.fn === "worker_ack").map((c) => c.args.p_msg_id), [1]);
  assert.deepEqual([s.skipped, s.retried], [1, 1]);
});
