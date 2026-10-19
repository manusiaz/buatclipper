import assert from "node:assert/strict";
import { type PlatformAdapter, Retryable, type StoredToken, TokenExpired } from "../_shared/social/mod.ts";
import { fakeRpc } from "../_shared/testing.ts";
import { runRefresh } from "./refresh.ts";

const tok = (at: string) => JSON.stringify({ v: 1, access_token: at, refresh_token: "r" });

Deno.test("refresh-tokens: sukses → store_social_token + verified; ditolak → expired; Retryable → dilewati", async () => {
  const f = fakeRpc({
    worker_accounts_to_refresh: () => [
      { account_id: "a1", platform: "tiktok", token: tok("ok") },
      { account_id: "a2", platform: "tiktok", token: tok("dead") },
      { account_id: "a3", platform: "tiktok", token: tok("busy") },
      { account_id: "a4", platform: "tiktok", token: null },
    ],
    store_social_token: () => "sid",
    worker_account_status: () => null,
  });
  const adapter = {
    refreshToken: (t: StoredToken) => {
      if (t.access_token === "dead") return Promise.reject(new TokenExpired("invalid_grant"));
      if (t.access_token === "busy") return Promise.reject(new Retryable("429"));
      return Promise.resolve({ ...t, access_token: "new" });
    },
  } as unknown as PlatformAdapter;
  const s = await runRefresh({ rpc: f.rpc, adapter: () => adapter });
  assert.deepEqual(f.calls[0].args, { p_within: "12 hours" });
  const status = Object.fromEntries(f.calls.filter((c) => c.fn === "worker_account_status").map((c) => [c.args.p_account, c.args.p_status]));
  assert.deepEqual(status, { a1: "verified", a2: "expired", a4: "expired" });
  const stored = f.calls.filter((c) => c.fn === "store_social_token");
  assert.deepEqual(stored.map((c) => [c.args.p_account_id, JSON.parse(c.args.p_token as string).access_token]), [["a1", "new"]]);
  assert.deepEqual([s.refreshed, s.expired, s.retried], [1, 2, 1]);
});
