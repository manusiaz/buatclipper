// identity/admin-auth — Auth Admin API with the identity secret key (§15.6, F-A07, alur 5). Caller: admin JWT aal2,
// role re-checked against E-27. Roles are granted elsewhere (api.admin_set_role).
//   invite_user {email, org_hint?}   admin_ops       managed-package PIC invite → ACCOUNTS_URL/auth/confirm
//   ban_user {user_id, duration}     admin_moderator ban_duration ("<hours>h" | "permanent")
//   unban_user {user_id}             admin_moderator
//   reset_mfa {user_id}              admin_super     delete every MFA factor (lost authenticator)
import { type AdminRole, type Claims, requireAdmin, requireAdminFresh } from "../_shared/auth.ts";
import type { AuthAdmin, Rpc } from "../_shared/db.ts";
import { action, HttpError, okResponse, readJson, str, uuid, wrap } from "../_shared/http.ts";
import { banUser, unbanUser } from "../_shared/moderation.ts";
import { safeBaseUrl } from "../_shared/templates.ts";

export interface AdminAuthDeps {
  verifyJwt: (req: Request) => Promise<Claims>;
  rpc: Rpc;
  authAdmin: AuthAdmin;
  accountsUrl: () => string;
}

const ROLES: Record<string, readonly AdminRole[]> = {
  invite_user: ["admin_ops"],
  ban_user: ["admin_moderator"],
  unban_user: ["admin_moderator"],
  reset_mfa: ["admin_super"],
};

const EMAIL_RE =
  /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

export function createAdminAuthHandler(deps: AdminAuthDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "admin-auth", cors: true }, async (req) => {
    const claims = await deps.verifyJwt(req);
    requireAdmin(claims, ["admin_ops", "admin_moderator"]);
    const body = await readJson(req, 8 * 1024);
    const act = action(body);
    const roles = ROLES[act];
    if (!roles) throw new HttpError(400, "unknown_action", "action tidak dikenal");
    const { isSuper } = await requireAdminFresh(
      claims,
      roles,
      async (u) => (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: u })) ?? [],
    );
    const actor = { id: claims.sub, isSuper };

    switch (act) {
      case "invite_user": {
        const email = str(body, "email", { max: 254 }).trim().toLowerCase();
        if (!EMAIL_RE.test(email)) throw new HttpError(400, "invalid_email", "email tidak valid");
        const orgHint = str(body, "org_hint", { max: 100, optional: true }).trim();
        const redirectTo = `${safeBaseUrl(deps.accountsUrl(), "ACCOUNTS_URL")}/auth/confirm`;
        const u = await deps.authAdmin.invite(email, redirectTo, orgHint ? { org_hint: orgHint } : {});
        await deps.rpc.invoke("svc_audit", {
          p_actor: actor.id,
          p_action: "auth.invite",
          p_target: `user:${u.id}`,
          p_after: orgHint ? { org_hint: orgHint } : null,
        });
        return okResponse({ user_id: u.id });
      }
      case "ban_user":
        return okResponse(await banUser(deps, actor, uuid(body, "user_id"), body.duration));
      case "unban_user":
        return okResponse(await unbanUser(deps, actor, uuid(body, "user_id")));
      default: {
        const userId = uuid(body, "user_id");
        if (userId === actor.id) throw new HttpError(400, "cannot_reset_self", "MFA sendiri direset admin_super lain");
        const factors = await deps.authAdmin.listFactors(userId);
        for (const f of factors) await deps.authAdmin.deleteFactor(userId, f.id);
        await deps.rpc.invoke("svc_audit", {
          p_actor: actor.id,
          p_action: "auth.reset_mfa",
          p_target: `user:${userId}`,
          p_after: { factors_deleted: factors.length },
        });
        return okResponse({ user_id: userId, factors_deleted: factors.length });
      }
    }
  });
}
