import { assertEquals } from "@std/assert";
import { claims, FakeAuthAdmin, FakeCore, FakeRpc, FakeStorage, json, post } from "../_shared/testing.ts";
import { createDeleteAccountHandler, retainUntil } from "./handler.ts";

const UID = "00000000-0000-0000-0000-0000000000a1";
const NOW = new Date("2026-10-19T03:00:00Z");

function setup(opts: { close?: unknown; kyc?: unknown[]; bannedUntil?: string | null; roles?: string[] } = {}) {
  const rpc = new FakeRpc({
    svc_platform_roles: () => opts.roles ?? [],
    svc_kyc: () => opts.kyc ?? [],
    svc_close_member: () => ({ kyc: "tombstoned", payout_methods_deleted: 0, payout_methods_tombstoned: 1 }),
  });
  const core = new FakeCore({ close_account: () => opts.close ?? { ok: true } });
  const storage = new FakeStorage();
  storage.files.set(`kyc-docs/${UID}/ktp.jpg`, { body: new Uint8Array([1]), contentType: "image/jpeg" });
  storage.files.set(`kyc-docs/${UID}/ktp-2.jpg`, { body: new Uint8Array([1]), contentType: "image/jpeg" });
  storage.files.set(`kyc-docs/00000000-0000-0000-0000-0000000000b1/ktp.jpg`, {
    body: new Uint8Array([1]),
    contentType: "image/jpeg",
  });
  const authAdmin = new FakeAuthAdmin();
  authAdmin.users.set(UID, { id: UID, email: "a@contoh.id", banned_until: opts.bannedUntil ?? null });
  const handler = createDeleteAccountHandler({
    verifyJwt: () => Promise.resolve(claims(UID)),
    rpc,
    core: () => core,
    storage,
    authAdmin,
    now: () => NOW,
  });
  return { rpc, core, storage, authAdmin, handler };
}

Deno.test("delete-account: confirm required", async () => {
  const s = setup();
  assertEquals((await json(await s.handler(post({})))).body.error.code, "confirm_required");
  assertEquals(s.core.calls.length, 0);
});

Deno.test("delete-account: core refusal (open balance/payout) → 409 with core's reason, nothing deleted", async () => {
  const s = setup({ close: { ok: false, reason: "balance_open" } });
  const res = await json(await s.handler(post({ confirm: true })));
  assertEquals([res.status, res.body.error.code], [409, "balance_open"]);
  assertEquals(s.rpc.named("svc_close_member").length + s.authAdmin.deleted.length, 0);
  assertEquals(s.storage.files.size, 3);
});

Deno.test("delete-account: banned + approved KYC → blocked tombstone kept 10 years, photos and Auth user removed", async () => {
  const s = setup({
    bannedUntil: "2126-01-01T00:00:00Z",
    kyc: [{ user_id: UID, legal_name: "A", nik_enc: "\\x00", enc_key_version: 1, status: "approved", closed: false }],
  });
  const res = await json(await s.handler(post({ confirm: true })));
  assertEquals(res.status, 200);
  assertEquals(s.core.named("close_account")[0].payload, { user_id: UID });
  assertEquals(s.rpc.named("svc_close_member")[0].args, { p_user: UID, p_blocked: true, p_retain_until: "2036-10-19" });
  assertEquals([...s.storage.files.keys()], ["kyc-docs/00000000-0000-0000-0000-0000000000b1/ktp.jpg"]);
  assertEquals(s.authAdmin.deleted, [UID]);
});

Deno.test("delete-account: expired ban + pending KYC → not blocked, no retention", async () => {
  const s = setup({
    bannedUntil: "2026-01-01T00:00:00Z",
    kyc: [{ user_id: UID, legal_name: "A", nik_enc: "\\x00", enc_key_version: 1, status: "pending", closed: false }],
  });
  await s.handler(post({ confirm: true }));
  assertEquals(s.rpc.named("svc_close_member")[0].args, { p_user: UID, p_blocked: false, p_retain_until: null });
});

Deno.test("delete-account: admin accounts are refused", async () => {
  const s = setup({ roles: ["admin_finance"] });
  assertEquals((await json(await s.handler(post({ confirm: true })))).body.error.code, "admin_account");
  assertEquals(s.core.calls.length, 0);
});

Deno.test("retainUntil: +10 years, 29 Feb → 28 Feb", () => {
  assertEquals(retainUntil({ y: 2026, m: 10, d: 19 }), "2036-10-19");
  assertEquals(retainUntil({ y: 2028, m: 2, d: 29 }), "2038-02-28");
});
