// Autentikasi pemanggil (PRD §15.6): semua fungsi verify_jwt = false dan mengecek sendiri.
//  - user  → JWT identity (ES256 ber-kid) diverifikasi lewat JWKS identity.
//  - cron  → header apikey = secret key core (pg_cron + pg_net, policy:fn-cron-key).
//  - bridge → HMAC (lihat bridge.ts).
import { createRemoteJWKSet, type JWTPayload, jwtVerify, type JWTVerifyGetKey } from "jose";
import { HttpError, safeEqual } from "./http.ts";

export interface User {
  id: string;
  roles: string[];
  aal: string | null;
  kyc: string | null;
  jwt: string;
  claims: JWTPayload;
}

let cachedJwks: { url: string; jwks: JWTVerifyGetKey } | null = null;

function jwksFromEnv(): JWTVerifyGetKey {
  const issuer = Deno.env.get("IDENTITY_ISSUER");
  const url = Deno.env.get("IDENTITY_JWKS_URL") ?? (issuer ? `${issuer.replace(/\/+$/, "")}/.well-known/jwks.json` : "");
  if (!url) throw new HttpError(500, "misconfigured", "env IDENTITY_JWKS_URL belum diset");
  if (cachedJwks?.url !== url) cachedJwks = { url, jwks: createRemoteJWKSet(new URL(url), { cacheMaxAge: 10 * 60_000 }) };
  return cachedJwks.jwks;
}

export interface JwtOptions {
  jwks?: JWTVerifyGetKey;
  issuer?: string;
}

export async function verifyUserJwt(req: Request, opts: JwtOptions = {}): Promise<User> {
  const m = /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") ?? "");
  if (!m) throw new HttpError(401, "unauthorized", "token tidak ada");
  const issuer = opts.issuer ?? Deno.env.get("IDENTITY_ISSUER");
  if (!issuer) throw new HttpError(500, "misconfigured", "env IDENTITY_ISSUER belum diset");
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(m[1], opts.jwks ?? jwksFromEnv(), {
      issuer,
      audience: "authenticated",
      algorithms: ["ES256"],
    }));
  } catch {
    throw new HttpError(401, "unauthorized", "token tidak valid");
  }
  if (!payload.sub || payload.role !== "authenticated" || payload.is_anonymous === true) {
    throw new HttpError(401, "unauthorized", "token tidak valid");
  }
  return {
    id: payload.sub,
    roles: Array.isArray(payload.app_roles) ? payload.app_roles.map(String) : [],
    aal: typeof payload.aal === "string" ? payload.aal : null,
    kyc: typeof payload.kyc === "string" ? payload.kyc : null,
    jwt: m[1],
    claims: payload,
  };
}

/** Secret key core yang sah: legacy service_role dan/atau key baru di SUPABASE_SECRET_KEYS (JSON objek atau array). */
export function serviceKeys(): string[] {
  const keys: string[] = [];
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) keys.push(legacy);
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const v = JSON.parse(raw);
      for (const k of Array.isArray(v) ? v : Object.values(v ?? {})) if (typeof k === "string" && k) keys.push(k);
    } catch {
      console.error("SUPABASE_SECRET_KEYS bukan JSON");
    }
  }
  return keys;
}

export async function requireApiKey(req: Request): Promise<void> {
  const given = req.headers.get("apikey") ?? "";
  const keys = serviceKeys();
  if (!given || keys.length === 0) throw new HttpError(401, "unauthorized");
  let ok = false;
  for (const k of keys) ok = (await safeEqual(given, k)) || ok; // cek semua key, tanpa short-circuit
  if (!ok) throw new HttpError(401, "unauthorized");
}
