// core/refresh-tokens (§11, R-08): refresh token sosmed yang kedaluwarsa dalam 12 jam (TikTok 24 jam, IG/Threads 60 hari).
// Sukses → store_social_token (Vault) + status verified. Refresh ditolak platform → status expired (minta reconnect).
import type { Rpc } from "../_shared/db.ts";
import { parseToken, type Platform, type PlatformAdapter, Retryable, TokenExpired } from "../_shared/social/mod.ts";

export interface RefreshDeps {
  rpc: Rpc;
  adapter: (p: Platform) => PlatformAdapter;
  now?: () => number;
  budgetMs?: number;
  within?: string;
}

export interface RefreshRow {
  account_id: string;
  platform: Platform;
  token: string | null;
}

export interface RefreshSummary {
  checked: number;
  refreshed: number;
  expired: number;
  retried: number;
  failed: number;
}

export async function runRefresh(deps: RefreshDeps): Promise<RefreshSummary> {
  const now = deps.now ?? Date.now;
  const deadline = now() + (deps.budgetMs ?? 50_000);
  const s: RefreshSummary = { checked: 0, refreshed: 0, expired: 0, retried: 0, failed: 0 };
  const rows = (await deps.rpc<RefreshRow[] | null>("worker_accounts_to_refresh", { p_within: deps.within ?? "12 hours" })) ?? [];
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(4, rows.length) }, async () => {
    while (i < rows.length && now() < deadline) {
      const row = rows[i++];
      s.checked++;
      try {
        const token = parseToken(row.token);
        if (!token) throw new TokenExpired("token tidak ada");
        const fresh = await deps.adapter(row.platform).refreshToken(token);
        await deps.rpc("store_social_token", { p_account_id: row.account_id, p_token: JSON.stringify(fresh) });
        await deps.rpc("worker_account_status", { p_account: row.account_id, p_status: "verified" });
        s.refreshed++;
      } catch (e) {
        if (e instanceof TokenExpired) {
          await deps.rpc("worker_account_status", { p_account: row.account_id, p_status: e.revoked ? "revoked" : "expired" });
          s.expired++;
        } else if (e instanceof Retryable) {
          s.retried++; // dicoba lagi di jadwal berikutnya (tiap 6 jam, jendela 12 jam)
        } else {
          console.error("refresh failed", row.account_id, row.platform, e instanceof Error ? e.message : e);
          s.failed++;
        }
      }
    }
  }));
  return s;
}
