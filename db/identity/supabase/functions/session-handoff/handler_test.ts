import { assert, assertEquals } from "@std/assert";
import { toPgBytea } from "../_shared/crypto.ts";
import { DbError } from "../_shared/db.ts";
import { HttpError } from "../_shared/http.ts";
import { claims, FakeAuthAdmin, FakeRpc, json, post } from "../_shared/testing.ts";
import { createSessionHandoffHandler } from "./handler.ts";

const UID = "00000000-0000-0000-0000-0000000000a1";
const ADMIN = "00000000-0000-0000-0000-0000000000ad";
const LINKS = {
  app: "https://app.clipper.test",
  brand: "https://brand.clipper.test",
  accounts: "https://accounts.clipper.test",
  admin: "https://admin.clipper.test",
};
const PUB = { apikey: "sb_publishable_test" };

/** Meniru api.svc_create_handoff / svc_redeem_handoff (semantik SQL-nya dites pgTAP identity_svc). */
function setup(opts: { roles?: Record<string, string[]>; jwtRoles?: string[] } = {}) {
  let now = Date.parse("2026-10-21T10:00:00Z");
  const rows = new Map<string, { user_id: string; next: string; expires_at: number; used_at: number | null }>();
  const rpc = new FakeRpc({
    svc_platform_roles: (a) => opts.roles?.[a.p_user as string] ?? [],
    svc_create_handoff: (a) => {
      const active = [...rows.values()].filter((r) => r.user_id === a.p_user && r.expires_at > now).length;
      if (active >= 10) throw new DbError("54000", "terlalu banyak kode handoff aktif");
      rows.set(a.p_code_hash as string, {
        user_id: a.p_user as string,
        next: a.p_next as string,
        expires_at: now + 60_000,
        used_at: null,
      });
      return new Date(now + 60_000).toISOString();
    },
    svc_redeem_handoff: (a) => {
      const r = rows.get(a.p_code_hash as string);
      if (!r || r.used_at !== null || r.expires_at <= now) return [];
      r.used_at = now;
      return [{ user_id: r.user_id, next: r.next }];
    },
  });
  const authAdmin = new FakeAuthAdmin();
  authAdmin.users.set(UID, { id: UID, email: "andi@contoh.id", banned_until: null });
  let jwtUser = UID;
  const handler = createSessionHandoffHandler({
    verifyJwt: (req) =>
      req.headers.get("authorization") === "Bearer user.jwt.token"
        ? Promise.resolve(claims(jwtUser, { roles: opts.jwtRoles }))
        : Promise.reject(new HttpError(401, "unauthorized", "login dulu")),
    isPublishable: (req) => req.headers.get("apikey") === PUB.apikey,
    rpc,
    authAdmin,
    links: () => LINKS,
    now: () => now,
  });
  const create = async (next: string) =>
    await json(await handler(post({ action: "create", next }, { authorization: "Bearer user.jwt.token" })));
  const redeem = async (code: unknown, headers: Record<string, string> = PUB) =>
    await json(await handler(post({ action: "redeem", code }, headers)));
  return {
    rpc,
    rows,
    authAdmin,
    create,
    redeem,
    handler,
    tick: (ms: number) => (now += ms),
    as: (id: string) => (jwtUser = id),
  };
}

Deno.test("session-handoff create: 32-byte base64url code, only sha256 stored, url to accounts/handoff", async () => {
  const s = setup();
  const res = await s.create("https://app.clipper.test/wallet?tab=reward#top");
  assertEquals(res.status, 200);
  const code = res.body.data.code as string;
  assert(/^[A-Za-z0-9_-]{43}$/.test(code));
  assertEquals(res.body.data.url, `https://accounts.clipper.test/handoff?code=${code}`);
  const args = s.rpc.named("svc_create_handoff")[0].args;
  const hash = toPgBytea(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code))));
  assertEquals(args, { p_user: UID, p_code_hash: hash, p_next: "https://app.clipper.test/wallet?tab=reward#top" });
  assert(!JSON.stringify(args).includes(code));
  const other = await s.create("https://accounts.clipper.test/kyc");
  assert(other.body.data.code !== code);
});

Deno.test("session-handoff create: admin account rejected (JWT claim or fresh E-27 role), nothing stored", async () => {
  const claimAdmin = setup({ jwtRoles: ["admin_ops"] });
  const a = await claimAdmin.create("https://app.clipper.test/");
  assertEquals([a.status, a.body.error.code], [403, "admin_account"]);
  const fresh = setup({ roles: { [ADMIN]: ["admin_support"] } });
  fresh.as(ADMIN);
  const b = await fresh.create("https://app.clipper.test/");
  assertEquals([b.status, b.body.error.code], [403, "admin_account"]);
  assertEquals(claimAdmin.rpc.named("svc_create_handoff").length + fresh.rpc.named("svc_create_handoff").length, 0);
});

Deno.test("session-handoff create: next must be http(s) on accounts/app/brand host", async () => {
  const s = setup();
  for (
    const bad of [
      "https://admin.clipper.test/",
      "https://evil.test/https://app.clipper.test",
      "https://app.clipper.test.evil.test/",
      "http://app.clipper.test/", // skema beda = origin beda
      "javascript:alert(1)",
      "/wallet",
      "https://user:pass@app.clipper.test/",
      "",
    ]
  ) {
    const res = await s.create(bad);
    assertEquals(res.status, 400, bad);
  }
  assertEquals((await s.create("https://brand.clipper.test/org/x")).status, 200);
  assertEquals(s.rpc.named("svc_create_handoff").length, 1);
  assertEquals(
    (await json(await s.handler(post({ action: "create", next: "https://app.clipper.test/" })))).status,
    401,
  );
});

Deno.test("session-handoff redeem: token_hash + next for the code's user, single use", async () => {
  const s = setup();
  const { code } = (await s.create("https://app.clipper.test/wallet")).body.data;
  const first = await s.redeem(code);
  assertEquals(first.body, { ok: true, data: { token_hash: "hash-1", next: "https://app.clipper.test/wallet" } });
  assertEquals(s.authAdmin.magicLinks, ["andi@contoh.id"]);
  const again = await s.redeem(code);
  assertEquals([again.status, again.body.error.code], [400, "invalid_code"]);
  assertEquals(s.authAdmin.magicLinks.length, 1);
});

Deno.test("session-handoff redeem: expired after 60 s", async () => {
  const s = setup();
  const { code } = (await s.create("https://app.clipper.test/wallet")).body.data;
  s.tick(60_001);
  const res = await s.redeem(code);
  assertEquals([res.status, res.body.error.code], [400, "invalid_code"]);
  assertEquals(s.authAdmin.magicLinks.length, 0);
});

Deno.test("session-handoff redeem: publishable apikey required; malformed code refused before the database", async () => {
  const s = setup();
  const { code } = (await s.create("https://app.clipper.test/")).body.data;
  assertEquals((await s.redeem(code, {})).status, 401);
  assertEquals((await s.redeem(code, { apikey: "sb_secret_x" })).status, 401);
  for (const bad of ["short", `${code}x`, 42, null]) {
    assertEquals((await s.redeem(bad)).body.error.code, "invalid_code");
  }
  assertEquals(s.rpc.named("svc_redeem_handoff").length, 0);
  assertEquals((await s.redeem(code)).status, 200); // kode masih utuh setelah percobaan ditolak
});

Deno.test("session-handoff redeem: user banned or made admin after create → invalid_code, no magic link", async () => {
  const s = setup();
  const one = (await s.create("https://app.clipper.test/")).body.data.code;
  const two = (await s.create("https://app.clipper.test/")).body.data.code;
  s.authAdmin.users.set(UID, { id: UID, email: "andi@contoh.id", banned_until: "2126-01-01T00:00:00Z" });
  assertEquals((await s.redeem(one)).body.error.code, "invalid_code");
  s.authAdmin.users.set(UID, { id: UID, email: "andi@contoh.id", banned_until: null });
  s.rpc.on("svc_platform_roles", () => ["admin_finance"]);
  assertEquals((await s.redeem(two)).body.error.code, "invalid_code");
  assertEquals(s.authAdmin.magicLinks.length, 0);
});

Deno.test("session-handoff create: rate limit 10 active codes per user → 429; expired ones free a slot", async () => {
  const s = setup();
  for (let i = 0; i < 10; i++) assertEquals((await s.create("https://app.clipper.test/")).status, 200);
  const limited = await s.create("https://app.clipper.test/");
  assertEquals([limited.status, limited.body.error.code], [429, "too_many_requests"]);
  s.tick(60_001);
  assertEquals((await s.create("https://app.clipper.test/")).status, 200);
});

Deno.test("session-handoff: code, token_hash and email never logged; unknown action refused", async () => {
  const lines: string[] = [];
  const orig = { log: console.log, warn: console.warn, error: console.error };
  console.log = console.warn = console.error = (...a: unknown[]) => void lines.push(a.map(String).join(" "));
  try {
    const s = setup();
    const { code } = (await s.create("https://app.clipper.test/")).body.data;
    await s.redeem(code);
    await s.redeem(code); // 400 → dicatat wrap
    await s.redeem(code, {}); // 401
    assertEquals((await json(await s.handler(post({ action: "x" })))).body.error.code, "unknown_action");
    const all = lines.join("\n");
    assert(lines.length >= 2);
    assert(!all.includes(code) && !all.includes("andi@contoh.id") && !all.includes("hash-1"));
  } finally {
    Object.assign(console, orig);
  }
});
