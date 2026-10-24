// Ban / unban through the Auth Admin API (ban_duration). Shared by admin-auth (admin_moderator, aal2) and the bridge
// action ban_user (core resolve_fraud_flag, §6 J-A4). A ban makes refresh fail; access tokens already issued stay valid
// ≤ 10 min, which core covers with the E-01 status (§15.6). Accounts holding a platform role can only be banned by
// admin_super — a moderator (or core) cannot lock out an admin.
import type { AuthAdmin, Rpc } from "./db.ts";
import { HttpError } from "./http.ts";

export const PERMANENT_BAN = "876000h"; // ~100 years, the value Supabase documents for a permanent ban

/** Accepts "<hours>h" (1–876000) or "permanent". Returns the Auth ban_duration string. */
export function normalizeBanDuration(raw: unknown): string {
  if (raw === "permanent") return PERMANENT_BAN;
  if (typeof raw === "string") {
    const m = /^(\d{1,6})h$/.exec(raw);
    if (m && Number(m[1]) >= 1 && Number(m[1]) <= 876000) return `${Number(m[1])}h`;
  }
  throw new HttpError(400, "invalid_duration", 'duration harus "<jam>h" (mis. "720h") atau "permanent"');
}

export interface ModerationDeps {
  authAdmin: AuthAdmin;
  rpc: Rpc;
}

async function assertBannable(deps: ModerationDeps, userId: string, actorIsSuper: boolean): Promise<void> {
  const roles = (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: userId })) ?? [];
  if (roles.length > 0 && !actorIsSuper) {
    throw new HttpError(403, "target_is_admin", "akun admin hanya bisa diubah admin_super");
  }
}

export async function banUser(
  deps: ModerationDeps,
  actor: { id: string | null; isSuper: boolean },
  userId: string,
  duration: unknown,
): Promise<{ user_id: string; banned_until: string | null }> {
  const banDuration = normalizeBanDuration(duration);
  if (actor.id === userId) throw new HttpError(400, "cannot_ban_self", "tidak bisa mem-ban akun sendiri");
  await assertBannable(deps, userId, actor.isSuper);
  const u = await deps.authAdmin.setBan(userId, banDuration);
  await deps.rpc.invoke("svc_audit", {
    p_actor: actor.id,
    p_action: "auth.ban",
    p_target: `user:${userId}`,
    p_after: {
      ban_duration: banDuration,
      banned_until: u.banned_until ?? null,
      via: actor.id ? "admin-auth" : "bridge",
    },
  });
  return { user_id: userId, banned_until: u.banned_until ?? null };
}

export async function unbanUser(
  deps: ModerationDeps,
  actor: { id: string | null; isSuper: boolean },
  userId: string,
): Promise<{ user_id: string; banned_until: null }> {
  await assertBannable(deps, userId, actor.isSuper);
  await deps.authAdmin.setBan(userId, "none");
  await deps.rpc.invoke("svc_audit", {
    p_actor: actor.id,
    p_action: "auth.unban",
    p_target: `user:${userId}`,
    p_after: null,
  });
  return { user_id: userId, banned_until: null };
}
