import { assert, assertEquals } from "@std/assert";
import { toPgBytea } from "../_shared/crypto.ts";
import { BridgeError } from "../_shared/bridge.ts";
import { HttpError } from "../_shared/http.ts";
import { claims, FakeCore, FakeRpc, FakeStorage, json, post, testCrypto } from "../_shared/testing.ts";
import { createPiiExportHandler, type PiiExportDeps } from "./handler.ts";

const crypto = testCrypto();
const BATCH = "00000000-0000-0000-0000-00000000b001";
const FIN = "00000000-0000-0000-0000-0000000000f1";
const u = (n: number) => `00000000-0000-0000-0000-0000000000${String(n).padStart(2, "0")}`;
const m = (n: number) => `00000000-0000-0000-0000-0000000001${String(n).padStart(2, "0")}`;
const p = (n: number) => `00000000-0000-0000-0000-0000000002${String(n).padStart(2, "0")}`;

async function method(n: number, user: string | null, over: Record<string, unknown> = {}) {
  const enc = await crypto.encrypt("payout.account_no", `888000${n}`);
  return {
    id: m(n),
    user_id: user,
    kind: "bank",
    bank_code: "BCA",
    account_no_enc: toPgBytea(enc.ciphertext),
    account_last4: "0000",
    enc_key_version: enc.version,
    account_name: `User ${n}`,
    disabled_at: null,
    blocked: false,
    ...over,
  };
}

async function setup(
  batch: Record<string, unknown> = {},
  roles = ["admin_finance"],
  aal = "aal2",
  attach: () => unknown = () => ({ ok: true }),
) {
  const methods = [
    await method(1, u(1), { account_name: "  user   1 " }), // ok (spacing/case differ from KYC)
    await method(2, u(99)), // belongs to another user
    await method(3, u(3), { disabled_at: "2026-10-18T00:00:00Z" }),
    await method(4, u(4)), // KYC pending
    await method(5, u(5), { account_name: "Someone Else" }),
    await method(7, null, { account_no_enc: null, enc_key_version: null, account_name: null, blocked: true }), // tombstone
    await method(8, u(8), { blocked: true }),
    await method(9, u(9), { account_name: "=cmd|' /C calc'!A0" }), // formula-looking name, matches KYC
  ];
  const kyc = (n: number, status = "approved", name = `User ${n}`) => ({
    user_id: u(n),
    legal_name: name,
    nik_enc: null,
    enc_key_version: null,
    status,
    closed: false,
  });
  const rpc = new FakeRpc({
    svc_platform_roles: () => roles,
    svc_payout_methods: (a) => methods.filter((x) => (a.p_ids as string[]).includes(x.id)),
    svc_kyc:
      () => [kyc(1), kyc(3), kyc(4, "pending"), kyc(5), kyc(7), kyc(8), kyc(9, "approved", "=cmd|' /C calc'!A0")],
    svc_audit: () => null,
  });
  const core = new FakeCore({
    get_batch: () => ({
      batch: { id: BATCH, status: "approved", created_by: u(50), approved_by: u(51), ...batch },
      payouts: [
        { id: p(1), user_id: u(1), method_id: m(1), amount: "150000.00" },
        { id: p(2), user_id: u(2), method_id: m(2), amount: "100000.00" },
        { id: p(3), user_id: u(3), method_id: m(3), amount: "100000.00" },
        { id: p(4), user_id: u(4), method_id: m(4), amount: "100000.00" },
        { id: p(5), user_id: u(5), method_id: m(5), amount: "100000.00" },
        { id: p(6), user_id: u(6), method_id: m(6), amount: "100000.00" }, // method unknown
        { id: p(7), user_id: u(7), method_id: m(7), amount: "100000.00" },
        { id: p(8), user_id: u(8), method_id: m(8), amount: "100000.00" },
        { id: p(1), user_id: u(1), method_id: m(1), amount: "150000.00" }, // duplicate row
        { id: p(9), user_id: u(9), method_id: m(9), amount: "120000.00" },
      ],
    }),
    attach_export: attach,
  });
  const storage = new FakeStorage();
  const deps: PiiExportDeps = {
    verifyJwt: () => Promise.resolve(claims(FIN, { aal, roles })),
    rpc,
    core: () => core,
    storage,
    crypto: () => crypto,
  };
  return { rpc, core, storage, handler: createPiiExportHandler(deps) };
}

Deno.test("payout_csv: hold rules, decrypted CSV, attach_export with held list, audit", async () => {
  const s = await setup();
  const res = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assertEquals(res.status, 200);
  assertEquals(res.body.data.rows, 2);
  assertEquals(res.body.data.expires_in, 900);
  const fileRef: string = res.body.data.file_ref;
  assert(fileRef.startsWith(`pii-exports/payouts/${BATCH}/`) && fileRef.endsWith(".csv"), fileRef);
  assertEquals(res.body.data.url, `https://storage.test/${fileRef}?ttl=900`);
  const held = [
    { payout_id: p(2), reason: "method_owner_mismatch" },
    { payout_id: p(3), reason: "method_disabled" },
    { payout_id: p(4), reason: "kyc_not_approved" },
    { payout_id: p(5), reason: "name_mismatch" },
    { payout_id: p(6), reason: "method_missing" },
    { payout_id: p(7), reason: "method_owner_mismatch" },
    { payout_id: p(8), reason: "method_disabled" },
    { payout_id: p(1), reason: "duplicate_payout" },
  ];
  assertEquals(res.body.data.held, held);
  assertEquals(
    s.storage.text(fileRef),
    "payout_id,bank_code,account_no,account_name,amount\r\n" +
      `${p(1)},BCA,8880001,  user   1 ,150000.00\r\n` +
      `${p(9)},BCA,8880009,'=cmd|' /C calc'!A0,120000.00\r\n`,
  );
  assertEquals(s.core.named("attach_export")[0].payload, {
    batch_id: BATCH,
    file_ref: fileRef,
    held,
    exported: [p(1), p(9)],
  });
  const audit = s.rpc.named("svc_audit")[0].args;
  assertEquals([audit.p_actor, audit.p_action, audit.p_target], [FIN, "pii.export_payouts", `batch:${BATCH}`]);
});

Deno.test("payout_csv: core rejects the handoff (export_stale) → CSV removed, error surfaced", async () => {
  const s = await setup({}, ["admin_finance"], "aal2", () => {
    throw new HttpError(422, "export_stale", "batch berubah");
  });
  const res = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assertEquals([res.status, res.body.error.code], [422, "export_stale"]);
  assertEquals(s.storage.files.size, 0);
});

Deno.test("payout_csv: core unreachable after upload → CSV kept (handoff may have committed)", async () => {
  const s = await setup({}, ["admin_finance"], "aal2", () => {
    throw new BridgeError(503, "core_unreachable", "timeout");
  });
  const res = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assertEquals(res.body.error.code, "core_unreachable");
  assertEquals(s.storage.files.size, 1);
});

Deno.test("payout_csv: concurrent exports write separate files (accepted CSV never overwritten)", async () => {
  const s = await setup();
  const a = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
  const b = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assert(a.body.data.file_ref !== b.body.data.file_ref);
  assertEquals(s.storage.files.size, 2);
});

Deno.test("payout_csv: only batches approved by a second person", async () => {
  for (const b of [{ approved_by: null, status: "draft" }, { approved_by: u(50) }, { status: "paid" }]) {
    const s = await setup(b);
    const res = await json(await s.handler(post({ action: "payout_csv", batch_id: BATCH })));
    assertEquals([res.status, res.body.error.code], [409, "batch_not_approved"]);
    assertEquals(s.storage.files.size + s.core.named("attach_export").length, 0);
  }
});

Deno.test("payout_csv: exported batch → new link for the same file, no re-decrypt, audited", async () => {
  const first = await setup();
  await json(await first.handler(post({ action: "payout_csv", batch_id: BATCH })));
  const accepted = first.core.named("attach_export")[0].payload.file_ref as string;
  const again = await setup({ status: "exported", file_ref: accepted });
  again.storage.files = first.storage.files;
  const res = await json(await again.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assertEquals(res.status, 200, JSON.stringify(res.body));
  assertEquals(res.body.data.file_ref, accepted);
  assertEquals(again.rpc.named("svc_payout_methods").length + again.core.named("attach_export").length, 0);
  assertEquals(again.rpc.named("svc_audit")[0].args.p_after, {
    resign: true,
    file_ref: accepted,
  });
  const missing = await setup({ status: "exported" });
  assertEquals(
    (await json(await missing.handler(post({ action: "payout_csv", batch_id: BATCH })))).body.error.code,
    "file_missing",
  );
});

Deno.test("pii-export: aal1 admin and wrong role are refused before any PII is read", async () => {
  const aal1 = await setup({}, ["admin_finance"], "aal1");
  assertEquals(
    (await json(await aal1.handler(post({ action: "payout_csv", batch_id: BATCH })))).body.error.code,
    "mfa_required",
  );
  const ops = await setup({}, ["admin_ops"]);
  const r = await json(await ops.handler(post({ action: "payout_csv", batch_id: BATCH })));
  assertEquals([r.status, r.body.error.code], [403, "forbidden"]);
  assertEquals(ops.core.calls.length + aal1.core.calls.length, 0);
});

Deno.test("recipients_csv: only users with share_with_brand consent; owner/reward type re-checked", async () => {
  const RT = "00000000-0000-0000-0000-0000000003aa";
  const enc = async (o: unknown) => toPgBytea((await crypto.encrypt("recipient.data", JSON.stringify(o))).ciphertext);
  const recips = [
    {
      id: m(61),
      user_id: u(61),
      reward_type_id: RT,
      data_enc: await enc({ address: "Jl. Mawar 1, Jakarta", phone: "+62812" }),
      enc_key_version: 1,
    },
    { id: m(63), user_id: u(99), reward_type_id: RT, data_enc: await enc({ address: "x" }), enc_key_version: 1 },
  ];
  const rpc = new FakeRpc({
    svc_platform_roles: () => ["admin_ops"],
    svc_has_consent: (a) => a.p_user !== u(62),
    svc_recipients: (a) => recips.filter((r) => (a.p_ids as string[]).includes(r.id)),
    svc_audit: () => null,
  });
  const core = new FakeCore({
    attach_fulfillment_export: () => ({ ok: true }),
    fulfillment_export: () => [
      { id: p(61), user_id: u(61), amount: 1, recipient: { game_id: "123", zone_id: "45" }, recipient_ref: m(61) },
      { id: p(62), user_id: u(62), amount: 1, recipient: { game_id: "9" }, recipient_ref: null },
      { id: p(63), user_id: u(63), amount: 1, recipient: {}, recipient_ref: m(63) },
      { id: p(64), user_id: u(64), amount: 1, recipient: {}, recipient_ref: m(64) },
    ],
  });
  const storage = new FakeStorage();
  const handler = createPiiExportHandler({
    verifyJwt: () => Promise.resolve(claims(FIN, { aal: "aal2", roles: ["admin_ops"] })),
    rpc,
    core: () => core,
    storage,
    crypto: () => crypto,
    now: () => new Date("2026-10-19T03:04:05Z"),
  });
  const res = await json(await handler(post({ action: "recipients_csv", reward_type_id: RT })));
  assertEquals(res.status, 200);
  assertEquals(res.body.data.skipped, [
    { fulfillment_id: p(62), reason: "no_consent" },
    { fulfillment_id: p(63), reason: "recipient_mismatch" },
    { fulfillment_id: p(64), reason: "recipient_missing" },
  ]);
  const fileRef: string = res.body.data.file_ref;
  assert(fileRef.startsWith(`pii-exports/recipients/${RT}/20261019T030405Z-`), fileRef);
  assertEquals(
    storage.text(fileRef),
    `fulfillment_id,amount,address,game_id,phone,zone_id\r\n${p(61)},1,"Jl. Mawar 1, Jakarta",123,'+62812,45\r\n`,
  );
  assertEquals(core.named("attach_fulfillment_export")[0].payload, {
    reward_type_id: RT,
    file_ref: fileRef,
    exported: [p(61)],
  });
  const again = await json(
    await handler(post({ action: "recipients_resign", reward_type_id: RT, file_ref: fileRef })),
  );
  assertEquals([again.status, again.body.data.url], [200, `https://storage.test/${fileRef}?ttl=900`]);
  assertEquals(rpc.named("svc_audit").at(-1)!.args.p_after, { resign: true, file_ref: fileRef });
  for (const bad of [`pii-exports/recipients/${m(1)}/x.csv`, `pii-exports/recipients/${RT}/../../payouts/x.csv`]) {
    const r = await json(await handler(post({ action: "recipients_resign", reward_type_id: RT, file_ref: bad })));
    assertEquals(r.body.error.code, "file_missing");
  }
});

Deno.test("upload_proof: type sniffed from content, stored in payout-proofs, attach_proof called", async () => {
  const core = new FakeCore({ attach_proof: () => ({ ok: true }) });
  const storage = new FakeStorage();
  const rpc = new FakeRpc({ svc_platform_roles: () => ["admin_finance"], svc_audit: () => null });
  const handler = createPiiExportHandler({
    verifyJwt: () => Promise.resolve(claims(FIN, { aal: "aal2", roles: ["admin_finance"] })),
    rpc,
    core: () => core,
    storage,
    crypto: () => crypto,
    now: () => new Date("2026-10-19T03:04:05Z"),
  });
  const pdf = btoa("%PDF-1.7\n...");
  const bad = await json(
    await handler(
      post({
        action: "upload_proof",
        target: "batch",
        id: BATCH,
        filename: "a.pdf",
        content_type: "image/png",
        content_base64: pdf,
      }),
    ),
  );
  assertEquals([bad.status, bad.body.error.code], [415, "unsupported_type"]);
  const ok = await json(
    await handler(
      post({
        action: "upload_proof",
        target: "batch",
        id: BATCH,
        filename: "../Bukti Transfer (1).pdf",
        content_type: "application/pdf",
        content_base64: pdf,
      }),
    ),
  );
  const ref = `payout-proofs/batch/${BATCH}/20261019T030405Z-Bukti-Transfer-1.pdf`;
  assertEquals(ok.body.data, { proof_ref: ref });
  assert(storage.files.has(ref));
  assertEquals(core.named("attach_proof")[0].payload, { target: "batch", id: BATCH, proof_ref: ref });
});

Deno.test("pph21: NIK + KTP name per user, gross as given, no tax computed", async () => {
  const nik = toPgBytea((await crypto.encrypt("kyc.nik", "3171011205900001")).ciphertext);
  const rpc = new FakeRpc({
    svc_platform_roles: () => ["admin_finance"],
    svc_kyc: () => [{
      user_id: u(1),
      legal_name: "Andi Saputra",
      nik_enc: nik,
      enc_key_version: 1,
      status: "approved",
      closed: true,
    }],
    svc_audit: () => null,
  });
  const core = new FakeCore({
    pph21: () => [{ user_id: u(1), gross: "1500000.00" }, { user_id: u(2), gross: "50000.00" }],
  });
  const storage = new FakeStorage();
  const handler = createPiiExportHandler({
    verifyJwt: () => Promise.resolve(claims(FIN, { aal: "aal2", roles: ["admin_finance"] })),
    rpc,
    core: () => core,
    storage,
    crypto: () => crypto,
  });
  const res = await json(await handler(post({ action: "pph21", from: "2026-09-01", to: "2026-09-30" })));
  assertEquals(res.status, 200, JSON.stringify(res.body));
  assertEquals(res.body.data.missing_kyc, [u(2)]);
  assertEquals(
    storage.text("pii-exports/pph21/2026-09-01_2026-09-30.csv"),
    `user_id,legal_name,nik,gross\r\n${u(1)},Andi Saputra,3171011205900001,1500000.00\r\n${u(2)},,,50000.00\r\n`,
  );
  const bad = await json(await handler(post({ action: "pph21", from: "2026-09-31", to: "2026-10-01" })));
  assertEquals(bad.body.error.code, "invalid_input");
});
