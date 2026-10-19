// Caller authentication for identity Edge Functions (all deployed with verify_jwt = false, §15.6):
//   user JWT  → verified against the identity JWKS (ES256/RS256), issuer IDENTITY_ISSUER, audience "authenticated".
//   admin     → user JWT + aal2 + platform role (admin_super always passes); optionally re-checked against E-27
//               because the app_roles claim can lag up to one JWT lifetime (10 min) after a revoke.
//   cron      → header apikey equal to the project's secret key (pg_cron → pg_net, member.invoke_function).
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { timingSafeEqual } from "./crypto.ts";
import { env, envJsonValues, envOpt, HttpError, isUuid } from "./http.ts";

export type AdminRole = "admin_super" | "admin_ops" | "admin_moderator" | "admin_finance" | "admin_support";

export interface Claims {
  sub: string;
  aal: string;
  app_roles: string[];
  kyc: string;
  email?: string;
  token: string;
}

export interface VerifyOptions {
  getKey?: JWTVerifyGetKey;
  issuer?: string;
}

let remoteJwks: JWTVerifyGetKey | undefined;

export function jwksUrl(): string {
  return envOpt("IDENTITY_JWKS_URL") ?? `${env("SUPABASE_URL").replace(/\/+$/, "")}/auth/v1/.well-known/jwks.json`;
}

function defaultKeyGetter(): JWTVerifyGetKey {
  remoteJwks ??= createRemoteJWKSet(new URL(jwksUrl()), { cacheMaxAge: 10 * 60_000, cooldownDuration: 30_000 });
  return remoteJwks;
}

export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(h.trim());
  return m ? m[1] : null;
}

export async function verifyUserJwt(req: Request, opts: VerifyOptions = {}): Promise<Claims> {
  const token = bearerToken(req);
  if (!token) throw new HttpError(401, "unauthorized", "login dulu");
  let payload: Record<string, unknown>;
  try {
    ({ payload } = await jwtVerify(token, opts.getKey ?? defaultKeyGetter(), {
      issuer: opts.issuer ?? env("IDENTITY_ISSUER"),
      audience: "authenticated",
      algorithms: ["ES256", "RS256"],
      clockTolerance: 5,
      requiredClaims: ["sub", "exp"],
    }));
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(401, "invalid_token", "sesi tidak sah atau kedaluwarsa");
  }
  if (!isUuid(payload.sub) || payload.role !== "authenticated" || payload.is_anonymous === true) {
    throw new HttpError(401, "invalid_token", "sesi tidak sah");
  }
  const roles = Array.isArray(payload.app_roles)
    ? payload.app_roles.filter((r): r is string => typeof r === "string")
    : [];
  return {
    sub: payload.sub.toLowerCase(),
    aal: typeof payload.aal === "string" ? payload.aal : "aal1",
    app_roles: roles,
    kyc: typeof payload.kyc === "string" ? payload.kyc : "none",
    email: typeof payload.email === "string" ? payload.email : undefined,
    token,
  };
}

function hasRole(have: readonly string[], roles: readonly AdminRole[]): boolean {
  return have.includes("admin_super") || roles.some((r) => have.includes(r));
}

/** Claim-level admin gate: aal2 + one of `roles` (admin_super always passes). */
export function requireAdmin(c: Claims, roles: readonly AdminRole[]): void {
  if (c.aal !== "aal2") throw new HttpError(403, "mfa_required", "aksi admin butuh MFA (aal2)");
  if (!hasRole(c.app_roles, roles)) throw new HttpError(403, "forbidden", "role admin tidak cukup");
}

/** Same gate, plus the current E-27 roles from the database (closes the ≤ 10 min window after a role revoke). */
export async function requireAdminFresh(
  c: Claims,
  roles: readonly AdminRole[],
  currentRoles: (userId: string) => Promise<string[]>,
): Promise<{ isSuper: boolean }> {
  requireAdmin(c, roles);
  const fresh = await currentRoles(c.sub);
  if (!hasRole(fresh, roles)) throw new HttpError(403, "forbidden", "role admin sudah dicabut");
  return { isSuper: fresh.includes("admin_super") };
}

/** pg_cron/pg_net caller: header apikey = SUPABASE_SERVICE_ROLE_KEY or one of SUPABASE_SECRET_KEYS. */
export function isCronRequest(req: Request): boolean {
  const key = req.headers.get("apikey");
  if (!key) return false;
  const candidates = [envOpt("SUPABASE_SERVICE_ROLE_KEY"), ...envJsonValues("SUPABASE_SECRET_KEYS")]
    .filter((v): v is string => !!v);
  let match = false;
  for (const c of candidates) match = timingSafeEqual(key, c) || match;
  return match;
}
