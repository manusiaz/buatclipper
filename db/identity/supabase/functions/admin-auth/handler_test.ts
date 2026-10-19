import { assertEquals } from "@std/assert";
import { claims, FakeAuthAdmin, FakeRpc, json, post } from "../_shared/testing.ts";
import { createAdminAuthHandler } from "./handler.ts";

const ADMIN = "00000000-0000-0000-0000-0000000000ad";
const USER = "00000000-0000-0000-0000-0000000000a1";
const OTHER_ADMIN = "00000000-0000-0000-0000-0000000000ae";

function setup(roles: string[], aal = "aal2") {
  const rpc = new FakeRpc({
    svc_platform_roles: (a) => (a.p_user === ADMIN ? roles : a.p_user === OTHER_ADMIN ? ["admin_finance"] : []),
    svc_audit: () => null,
  });
  const authAdmin = new FakeAuthAdmin();
  authAdmin.factors.set(OTHER_ADMIN, ["f1", "f2"]);
  const handler = createAdminAuthHandler({
    verifyJwt: () => Promise.resolve(claims(ADMIN, { aal, roles })),
    rpc,
    authAdmin,
    accountsUrl: () => "https://accounts.clipper.test/",
  });
  return { rpc, authAdmin, handler };
}

Deno.test("admin-auth: aal1 admin is rejected", async () => {
  const s = setup(["admin_super"], "aal1");
  const r = await json(await s.handler(post({ action: "ban_user", user_id: USER, duration: "720h" })));
  assertEquals([r.status, r.body.error.code], [403, "mfa_required"]);
  assertEquals(s.authAdmin.bans.length, 0);
});

Deno.test("admin-auth: moderator bans a clipper; cannot ban an admin; bad duration refused", async () => {
  const s = setup(["admin_moderator"]);
  const ok = await json(await s.handler(post({ action: "ban_user", user_id: USER, duration: "permanent" })));
  assertEquals(ok.status, 200);
  assertEquals(s.authAdmin.bans, [{ id: USER, duration: "876000h" }]);
  assertEquals(s.rpc.named("svc_audit")[0].args.p_action, "auth.ban");
  assertEquals(
    (await json(await s.handler(post({ action: "ban_user", user_id: OTHER_ADMIN, duration: "1h" })))).body.error.code,
    "target_is_admin",
  );
  assertEquals(
    (await json(await s.handler(post({ action: "ban_user", user_id: USER, duration: "1d" })))).body.error.code,
    "invalid_duration",
  );
  await s.handler(post({ action: "unban_user", user_id: USER }));
  assertEquals(s.authAdmin.bans.at(-1), { id: USER, duration: "none" });
});

Deno.test("admin-auth: reset_mfa only for admin_super, never on self", async () => {
  const mod = setup(["admin_moderator"]);
  assertEquals(
    (await json(await mod.handler(post({ action: "reset_mfa", user_id: OTHER_ADMIN })))).body.error.code,
    "forbidden",
  );
  const sup = setup(["admin_super"]);
  const ok = await json(await sup.handler(post({ action: "reset_mfa", user_id: OTHER_ADMIN })));
  assertEquals(ok.body.data, { user_id: OTHER_ADMIN, factors_deleted: 2 });
  assertEquals(sup.authAdmin.factors.get(OTHER_ADMIN), []);
  assertEquals(
    (await json(await sup.handler(post({ action: "reset_mfa", user_id: ADMIN })))).body.error.code,
    "cannot_reset_self",
  );
});

Deno.test("admin-auth: invite_user (admin_ops) redirects to accounts /auth/confirm", async () => {
  const s = setup(["admin_ops"]);
  const r = await json(
    await s.handler(post({ action: "invite_user", email: " PIC@Brand.co.id ", org_hint: "Brand X" })),
  );
  assertEquals(typeof r.body.data.user_id, "string");
  assertEquals(s.authAdmin.invites, [
    {
      email: "pic@brand.co.id",
      redirectTo: "https://accounts.clipper.test/auth/confirm",
      data: { org_hint: "Brand X" },
    },
  ]);
  assertEquals(s.rpc.named("svc_audit")[0].args.p_target, `user:${r.body.data.user_id}`);
  assertEquals(
    (await json(await s.handler(post({ action: "invite_user", email: "not-an-email" })))).body.error.code,
    "invalid_email",
  );
});
