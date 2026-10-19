// core/track-worker (§11): kuras queue "tracking" dalam batch kecil sampai ±50 detik, kelompokkan per akun,
// fetchMetrics, lalu worker_record_snapshot (SQL: cek ulang caption via missing_brief_tags, fraud flag, accrue_earnings,
// jadwal poll berikutnya) / worker_post_gone / worker_account_status('expired'). Error API & rate limit tidak di-ack:
// pesan muncul lagi setelah visibility timeout. Tidak pernah menulis 0 views.
import { type Rpc, RpcError } from "../_shared/db.ts";
import {
  ensureFresh,
  isMetrics,
  type MetricResult,
  parseToken,
  type Platform,
  type PlatformAdapter,
  Retryable,
  type StoredToken,
  TokenExpired,
} from "../_shared/social/mod.ts";

export interface QueueMsg {
  msg_id: number;
  message: { submission_id?: string; platform?: string };
}

export interface SubmissionContext {
  submission: {
    id: string;
    platform: Platform;
    post_id: string;
    url: string;
    posted_at: string;
    status: string;
    user_id: string;
    campaign_id: string;
    counted_views: number;
    last_snapshot_at?: string | null;
  };
  account: { id: string; external_id: string; handle: string; status: string };
  token: string | null;
  campaign: Record<string, unknown>;
  final: boolean;
}

export interface TrackDeps {
  rpc: Rpc;
  adapter: (p: Platform) => PlatformAdapter;
  flags: () => Promise<Record<string, boolean>>;
  now?: () => number;
  budgetMs?: number;
  batch?: number;
  vtSeconds?: number;
}

export interface TrackSummary {
  dequeued: number;
  recorded: number;
  flagged: number;
  gone: number;
  expired: number;
  retried: number;
  skipped: number;
  failed: number;
  acked: number;
}

const TRACKABLE = new Set(["tracking", "flagged"]);
const H = 3_600_000;
/** X: baca berbayar → hanya di 24 jam, 7 hari, dan lock (§11). */
export const X_CHECKPOINTS_MS = [24 * H, 7 * 24 * H];
/** Tanpa last_snapshot_at, checkpoint dianggap jatuh tempo selama jendela ini (lease enqueue 1 jam + jeda cron 15 menit). */
export const X_SLACK_MS = 90 * 60_000;

export function xDue(ctx: SubmissionContext, now: number): boolean {
  if (ctx.final) return true;
  const posted = Date.parse(ctx.submission.posted_at);
  const age = now - posted;
  const last = ctx.submission.last_snapshot_at ? Date.parse(ctx.submission.last_snapshot_at) : null;
  return X_CHECKPOINTS_MS.some((cp) => age >= cp && (last !== null ? last < posted + cp : age < cp + X_SLACK_MS));
}

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>): Promise<void> {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) await fn(items[i++]);
  }));
}

interface Item {
  ctx: SubmissionContext;
  msgIds: number[];
}

export async function runTrackWorker(deps: TrackDeps): Promise<TrackSummary> {
  const now = deps.now ?? Date.now;
  const deadline = now() + (deps.budgetMs ?? 50_000);
  const s: TrackSummary = {
    dequeued: 0,
    recorded: 0,
    flagged: 0,
    gone: 0,
    expired: 0,
    retried: 0,
    skipped: 0,
    failed: 0,
    acked: 0,
  };
  const rpc = deps.rpc;
  const ack = async (ids: number[]) => {
    for (const id of ids) {
      await rpc("worker_ack", { p_queue: "tracking", p_msg_id: id });
      s.acked++;
    }
  };
  let flags: Record<string, boolean> | null = null;

  while (now() < deadline - 5_000) {
    const msgs = (await rpc<QueueMsg[] | null>("worker_dequeue", {
      p_queue: "tracking",
      p_qty: deps.batch ?? 20,
      p_vt_seconds: deps.vtSeconds ?? 300,
    })) ?? [];
    if (!msgs.length) break;
    s.dequeued += msgs.length;
    flags ??= await deps.flags(); // gagal → seluruh run berhenti, pesan kembali setelah visibility timeout

    // Satu submisi bisa muncul dua kali (lease enqueue lewat sebelum pesan lama di-ack): proses sekali, ack semua.
    const bySub = new Map<string, number[]>();
    for (const m of msgs) {
      const id = m.message?.submission_id;
      if (!id) {
        await ack([m.msg_id]);
        s.skipped++;
        continue;
      }
      bySub.set(id, [...(bySub.get(id) ?? []), m.msg_id]);
    }

    const groups = new Map<string, { platform: Platform; token: StoredToken; items: Item[] }>();
    await pool([...bySub.entries()], 5, async ([subId, msgIds]) => {
      let ctx: SubmissionContext | null;
      try {
        ctx = await rpc<SubmissionContext | null>("worker_submission_context", { p_submission: subId });
      } catch (e) {
        if (e instanceof RpcError && e.code === "P0002") {
          await ack(msgIds); // submisi sudah tidak ada
          s.skipped++;
          return;
        }
        console.error("track context failed", subId, e instanceof Error ? e.message : e);
        s.retried++;
        return;
      }
      const sub = ctx?.submission;
      const token = parseToken(ctx?.token);
      const skip = !ctx || !sub || !TRACKABLE.has(sub.status) || flags![sub.platform] !== true ||
        ctx.account?.status !== "verified" || !token || (sub.platform === "x" && !xDue(ctx, now()));
      if (skip || !ctx || !sub || !token) {
        // Submisi basi / platform mati / tracking pause (token) / X belum checkpoint: ack, enqueue berikutnya menjadwal ulang.
        await ack(msgIds);
        s.skipped++;
        return;
      }
      const g = groups.get(ctx.account.id) ?? { platform: sub.platform, token, items: [] };
      g.items.push({ ctx, msgIds });
      groups.set(ctx.account.id, g);
    });

    await pool([...groups.entries()], 3, async ([accountId, g]) => {
      const adapter = deps.adapter(g.platform);
      let token: StoredToken;
      try {
        token = await ensureFresh(adapter, g.token, accountId, rpc, now());
      } catch (e) {
        await onBatchError(e, accountId, g.items);
        return;
      }
      // Post yang sama bisa disubmit ke beberapa campaign (allow_video_reuse): ambil sekali, catat per submisi.
      for (const final of [false, true]) {
        const items = g.items.filter((it) => it.ctx.final === final);
        const byPost = new Map<string, Item[]>();
        for (const it of items) {
          byPost.set(it.ctx.submission.post_id, [...(byPost.get(it.ctx.submission.post_id) ?? []), it]);
        }
        const postIds = [...byPost.keys()];
        for (let i = 0; i < postIds.length; i += adapter.maxBatch) {
          if (now() >= deadline) return; // sisa pesan kembali setelah visibility timeout
          const ids = postIds.slice(i, i + adapter.maxBatch);
          const postedAt = Object.fromEntries(ids.map((id) => [id, byPost.get(id)![0].ctx.submission.posted_at]));
          let results: MetricResult[];
          try {
            results = await adapter.fetchMetrics(token, ids, { final, postedAt });
          } catch (e) {
            const stop = await onBatchError(e, accountId, ids.flatMap((id) => byPost.get(id)!));
            if (stop) return;
            continue;
          }
          const seen = new Set<string>();
          for (const r of results) {
            seen.add(r.postId);
            for (const it of byPost.get(r.postId) ?? []) await handleResult(r, it);
          }
          s.retried += ids.filter((id) => !seen.has(id)).reduce((n, id) => n + byPost.get(id)!.length, 0);
        }
      }
    });
  }
  return s;

  /** true = hentikan akun ini. */
  async function onBatchError(e: unknown, accountId: string, items: Item[]): Promise<boolean> {
    if (e instanceof TokenExpired) {
      // Tracking pause sampai reconnect (§11); views kumulatif tetap terhitung setelah reconnect.
      await rpc("worker_account_status", { p_account: accountId, p_status: e.revoked ? "revoked" : "expired" });
      s.expired++;
      await ack(items.flatMap((it) => it.msgIds));
      return true;
    }
    if (e instanceof Retryable) {
      s.retried += items.length;
      return false;
    }
    console.error("track batch failed", accountId, e instanceof Error ? e.message : e);
    s.failed += items.length;
    await ack(items.flatMap((it) => it.msgIds));
    return false;
  }

  async function handleResult(r: MetricResult, it: Item): Promise<void> {
    const subId = it.ctx.submission.id;
    try {
      if (isMetrics(r)) {
        const res = await rpc<{ flagged?: boolean } | null>("worker_record_snapshot", {
          p_submission: subId,
          p_views: r.views,
          p_likes: r.likes,
          p_comments: r.comments,
          p_shares: r.shares,
          p_caption: r.caption,
          p_raw: r.raw ?? null,
          p_extra: r.extra ?? {},
        });
        s.recorded++;
        if (res?.flagged) s.flagged++;
      } else if ("gone" in r) {
        await rpc("worker_post_gone", { p_submission: subId, p_reason: r.reason });
        s.gone++;
      } else if ("retry" in r) {
        s.retried++;
        return;
      } else {
        console.error("track post failed", subId, r.reason);
        s.failed++;
      }
      await ack(it.msgIds);
    } catch (e) {
      // RPC gagal → biarkan pesan, coba lagi setelah visibility timeout
      console.error("track rpc failed", subId, e instanceof Error ? e.message : e);
      s.retried++;
    }
  }
}
