import { assertEquals, assertRejects } from "@std/assert";
import { createLocalJWKSet, exportJWK, generateKeyPair, type KeyLike, SignJWT } from "jose";
import { isCronRequest, requireAdmin, requireAdminFresh, verifyUserJwt } from "./auth.ts";
import { HttpError } from "./http.ts";

const ISS = "https://auth.clipper.test/auth/v1";
const UID = "00000000-0000-0000-0000-0000000000a1";

const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
const other = await generateKeyPair("ES256", { extractable: true });
const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "ES256", use: "sig" };
const jwks = { keys: [jwk] };
const getKey = createLocalJWKSet(jwks);

async function token(
  claims: Record<string, unknown> = {},
  opts: { key?: KeyLike; iss?: string; aud?: string; exp?: string } = {},
) {
  return await new SignJWT({ role: "authenticated", aal: "aal1", app_roles: [], kyc: "none", ...claims })
    .setProtectedHeader({ alg: "ES256", kid: "k1" })
    .setSubject(UID)
    .setIssuer(opts.iss ?? ISS)
    .setAudience(opts.aud ?? "authenticated")
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? "10m")
    .sign(opts.key ?? privateKey);
}

function req(t?: string): Request {
  return new Request("http://localhost/x", { method: "POST", headers: t ? { authorization: `Bearer ${t}` } : {} });
}

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (err) {
    if (err instanceof HttpError) return err.code;
    throw err;
  }
  return "ok";
}

Deno.test("JWT: valid ES256 identity token → claims", async () => {
  const c = await verifyUserJwt(req(await token({ aal: "aal2", app_roles: ["admin_finance"], kyc: "approved" })), {
    getKey,
    issuer: ISS,
  });
  assertEquals(c.sub, UID);
  assertEquals(c.aal, "aal2");
  assertEquals(c.app_roles, ["admin_finance"]);
  assertEquals(c.kyc, "approved");
});

Deno.test("JWT: missing, wrong issuer/audience/key, expired, anonymous, non-authenticated role → 401", async () => {
  const o = { getKey, issuer: ISS };
  assertEquals(await code(verifyUserJwt(req(), o)), "unauthorized");
  assertEquals(
    await code(verifyUserJwt(req(await token({}, { iss: "https://evil.test/auth/v1" })), o)),
    "invalid_token",
  );
  assertEquals(await code(verifyUserJwt(req(await token({}, { aud: "anon" })), o)), "invalid_token");
  assertEquals(await code(verifyUserJwt(req(await token({}, { key: other.privateKey })), o)), "invalid_token");
  assertEquals(await code(verifyUserJwt(req(await token({}, { exp: "-1m" })), o)), "invalid_token");
  assertEquals(await code(verifyUserJwt(req(await token({ is_anonymous: true })), o)), "invalid_token");
  assertEquals(await code(verifyUserJwt(req(await token({ role: "service_role" })), o)), "invalid_token");
});

Deno.test("JWT: HS256 token (alg confusion) is rejected", async () => {
  const hs = await new SignJWT({ role: "authenticated" }).setProtectedHeader({ alg: "HS256", kid: "k1" }).setSubject(
    UID,
  )
    .setIssuer(ISS).setAudience("authenticated").setExpirationTime("10m").sign(
      new TextEncoder().encode("x".repeat(32)),
    );
  assertEquals(await code(verifyUserJwt(req(hs), { getKey, issuer: ISS })), "invalid_token");
});

Deno.test("JWT: remote JWKS (mocked server on localhost) + IDENTITY_ISSUER env", async () => {
  const ac = new AbortController();
  const server = Deno.serve(
    { hostname: "localhost", port: 0, signal: ac.signal, onListen() {} },
    () => Response.json(jwks),
  );
  Deno.env.set("IDENTITY_JWKS_URL", `http://localhost:${server.addr.port}/auth/v1/.well-known/jwks.json`);
  Deno.env.set("IDENTITY_ISSUER", ISS);
  try {
    assertEquals((await verifyUserJwt(req(await token()))).sub, UID);
    assertEquals(await code(verifyUserJwt(req(await token({}, { key: other.privateKey })))), "invalid_token");
  } finally {
    ac.abort();
    await server.finished;
  }
});

Deno.test("admin gate: aal1 admin rejected, role required, admin_super passes", async () => {
  const base = { sub: UID, kyc: "none", token: "t" };
  const e = (fn: () => void) => {
    try {
      fn();
      return "ok";
    } catch (err) {
      return (err as HttpError).code;
    }
  };
  assertEquals(
    e(() => requireAdmin({ ...base, aal: "aal1", app_roles: ["admin_finance"] }, ["admin_finance"])),
    "mfa_required",
  );
  assertEquals(
    e(() => requireAdmin({ ...base, aal: "aal2", app_roles: ["admin_support"] }, ["admin_finance"])),
    "forbidden",
  );
  assertEquals(e(() => requireAdmin({ ...base, aal: "aal2", app_roles: [] }, ["admin_finance"])), "forbidden");
  assertEquals(e(() => requireAdmin({ ...base, aal: "aal2", app_roles: ["admin_finance"] }, ["admin_finance"])), "ok");
  assertEquals(e(() => requireAdmin({ ...base, aal: "aal2", app_roles: ["admin_super"] }, ["admin_finance"])), "ok");
  // role revoked in E-27 but still in the (≤ 10 min old) JWT claim
  await assertRejects(
    () =>
      requireAdminFresh(
        { ...base, aal: "aal2", app_roles: ["admin_finance"] },
        ["admin_finance"],
        () => Promise.resolve([]),
      ),
    HttpError,
    "dicabut",
  );
  assertEquals(
    await requireAdminFresh(
      { ...base, aal: "aal2", app_roles: ["admin_super"] },
      ["admin_ops"],
      () => Promise.resolve(["admin_super"]),
    ),
    { isSuper: true },
  );
});

Deno.test("cron auth: apikey must equal the service role key or a SUPABASE_SECRET_KEYS value", () => {
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "legacy-service-key");
  Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: "sb_secret_abc" }));
  const r = (k?: string) => new Request("http://localhost/bridge", { method: "POST", headers: k ? { apikey: k } : {} });
  assertEquals(isCronRequest(r("legacy-service-key")), true);
  assertEquals(isCronRequest(r("sb_secret_abc")), true);
  assertEquals(isCronRequest(r("sb_publishable_xyz")), false);
  assertEquals(isCronRequest(r()), false);
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.delete("SUPABASE_SECRET_KEYS");
  assertEquals(isCronRequest(r("legacy-service-key")), false);
});
