import assert from "node:assert/strict";
import { exportJWK, generateKeyPair, type JWTPayload, type KeyLike, SignJWT } from "jose";
import { requireApiKey, verifyUserJwt } from "./auth.ts";
import { HttpError } from "./http.ts";

const ISS = "https://auth.clipper.test/auth/v1";
const { privateKey, publicKey } = await generateKeyPair("ES256");
const other = await generateKeyPair("ES256");
const jwk = { ...(await exportJWK(publicKey)), kid: "key-1", alg: "ES256", use: "sig" };

async function token(claims: JWTPayload = {}, opts: { key?: KeyLike; kid?: string; exp?: string } = {}) {
  return await new SignJWT({ role: "authenticated", app_roles: ["clipper"], aal: "aal1", kyc: "approved", ...claims })
    .setProtectedHeader({ alg: "ES256", kid: opts.kid ?? "key-1" })
    .setIssuer(String(claims.iss ?? ISS))
    .setAudience("authenticated")
    .setSubject("6f1c2d3e-4b5a-4c6d-8e7f-001122334455")
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? "10m")
    .sign(opts.key ?? privateKey);
}

const req = (t?: string) => new Request("https://core.test/functions/v1/social", { headers: t ? { authorization: `Bearer ${t}` } : {} });

/** JWKS remote dimock lewat fetch global (jose memakai fetch). */
function withJwks<T>(fn: () => Promise<T>): Promise<T> {
  const orig = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL) => {
    assert.equal(String(input instanceof Request ? input.url : input), `${ISS}/.well-known/jwks.json`);
    return Promise.resolve(new Response(JSON.stringify({ keys: [jwk] }), { headers: { "content-type": "application/json" } }));
  }) as typeof fetch;
  Deno.env.set("IDENTITY_ISSUER", ISS);
  Deno.env.set("IDENTITY_JWKS_URL", `${ISS}/.well-known/jwks.json`);
  return fn().finally(() => (globalThis.fetch = orig));
}

const unauthorized = (e: unknown) => e instanceof HttpError && e.status === 401;

Deno.test("jwt: token ES256 identity valid → user id = sub + claims", () =>
  withJwks(async () => {
    const u = await verifyUserJwt(req(await token()));
    assert.equal(u.id, "6f1c2d3e-4b5a-4c6d-8e7f-001122334455");
    assert.deepEqual([u.roles, u.aal, u.kyc], [["clipper"], "aal1", "approved"]);
  }));

Deno.test("jwt: tanpa token / issuer lain / key lain / kedaluwarsa / anon → 401", () =>
  withJwks(async () => {
    await assert.rejects(verifyUserJwt(req()), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({ iss: "https://evil.test/auth/v1" }))), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({}, { key: other.privateKey }))), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({}, { kid: "unknown" }))), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({}, { exp: "-1m" }))), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({ role: "anon" }))), unauthorized);
    await assert.rejects(verifyUserJwt(req(await token({ is_anonymous: true }))), unauthorized);
    await assert.rejects(verifyUserJwt(req("not.a.jwt")), unauthorized);
  }));

Deno.test("jwt: algoritma HS256 (secret bersama) ditolak", () =>
  withJwks(async () => {
    const hs = await new SignJWT({ role: "authenticated" }).setProtectedHeader({ alg: "HS256", kid: "key-1" }).setIssuer(ISS)
      .setAudience("authenticated").setSubject("x").setExpirationTime("5m").sign(new TextEncoder().encode("s".repeat(32)));
    await assert.rejects(verifyUserJwt(req(hs)), unauthorized);
  }));

Deno.test("apikey: secret key legacy & SUPABASE_SECRET_KEYS diterima, lainnya 401", async () => {
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "legacy-service-role");
  Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: "sb_secret_abc", cron: "sb_secret_cron" }));
  const r = (k?: string) => new Request("https://core.test/x", { method: "POST", headers: k ? { apikey: k } : {} });
  await requireApiKey(r("legacy-service-role"));
  await requireApiKey(r("sb_secret_cron"));
  await assert.rejects(requireApiKey(r("sb_secret_ab")), unauthorized);
  await assert.rejects(requireApiKey(r("sb_publishable_xyz")), unauthorized);
  await assert.rejects(requireApiKey(r()), unauthorized);
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.delete("SUPABASE_SECRET_KEYS");
  await assert.rejects(requireApiKey(r("legacy-service-role")), unauthorized);
});
