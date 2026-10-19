import { assert, assertEquals } from "@std/assert";
import { fromPgBytea, toHex, toPgBytea } from "../_shared/crypto.ts";
import { DbError } from "../_shared/db.ts";
import { claims, FakeRpc, FakeStorage, json, post, testCrypto } from "../_shared/testing.ts";
import { createMemberDataHandler, normalizeAccountNo, normalizeLegalName } from "./handler.ts";

const UID = "00000000-0000-0000-0000-0000000000a1";
const TODAY = { y: 2026, m: 10, d: 19 };
const crypto = testCrypto();

function setup(rpcHandlers: Record<string, (a: Record<string, unknown>) => unknown> = {}) {
  const rpc = new FakeRpc({
    store_kyc: () => null,
    store_payout_method: () => "00000000-0000-0000-0000-0000000001aa",
    store_recipient: () => "00000000-0000-0000-0000-0000000002aa",
    svc_kyc: () => [{
      user_id: UID,
      legal_name: "Andi Saputra",
      nik_enc: null,
      enc_key_version: null,
      status: "pending",
      closed: false,
    }],
    svc_audit: () => null,
    ...rpcHandlers,
  });
  const userRpc = new FakeRpc({ record_consent: () => null });
  const storage = new FakeStorage();
  storage.files.set(`kyc-docs/${UID}/ktp.jpg`, { body: new Uint8Array([1]), contentType: "image/jpeg" });
  const handler = createMemberDataHandler({
    verifyJwt: () => Promise.resolve(claims(UID)),
    rpc,
    userRpc: () => userRpc,
    storage,
    crypto: () => crypto,
    today: () => TODAY,
  });
  return { rpc, userRpc, storage, handler };
}

const kyc = (over: Record<string, unknown> = {}) =>
  post({
    action: "submit_kyc",
    legal_name: "  Andi   Saputra ",
    nik: "3171 0112 0590 0001",
    doc_path: `${UID}/ktp.jpg`,
    ...over,
  });

Deno.test("submit_kyc: consent first, then HMAC + ciphertext + last4 to store_kyc", async () => {
  const s = setup();
  const res = await json(await s.handler(kyc()));
  assertEquals(res.body, { ok: true, data: { status: "pending", nik_last4: "0001" } });
  assertEquals(s.userRpc.calls, [{ fn: "record_consent", args: { p_kind: "kyc" } }]);
  const a = s.rpc.named("store_kyc")[0].args;
  assertEquals(a.p_user_id, UID);
  assertEquals(a.p_legal_name, "Andi Saputra");
  assertEquals(a.p_doc_ref, `${UID}/ktp.jpg`);
  assertEquals(a.p_nik_last4, "0001");
  assertEquals(a.p_nik_hash, toPgBytea(await crypto.hmac("3171011205900001")));
  assertEquals(
    await crypto.decrypt("kyc.nik", fromPgBytea(a.p_nik_enc as string), a.p_key_version as number),
    "3171011205900001",
  );
  assert(!JSON.stringify(a).includes("3171011205900001")); // plaintext NIK never reaches the database
});

Deno.test("submit_kyc: under 18 (female +40), bad NIK, foreign folder, missing photo, NIK taken", async () => {
  const cases: [Record<string, unknown>, number, string][] = [
    [{ nik: "3171016010080002" }, 422, "under_age"], // female born 20 Oct 2008 → 17
    [{ nik: "3171013202900001" }, 422, "invalid_nik"], // 32 Feb
    [{ doc_path: `00000000-0000-0000-0000-0000000000b1/ktp.jpg` }, 400, "invalid_doc_path"],
    [{ doc_path: `${UID}/../x.jpg` }, 400, "invalid_doc_path"],
    [{ doc_path: `${UID}/missing.jpg` }, 422, "doc_missing"],
    [{ legal_name: "<script>" }, 400, "invalid_name"],
  ];
  for (const [over, status, code] of cases) {
    const s = setup();
    const res = await json(await s.handler(kyc(over)));
    assertEquals([res.status, res.body.error.code], [status, code], JSON.stringify(over));
    assertEquals(s.rpc.named("store_kyc").length, 0);
  }
  const taken = setup({
    store_kyc: () => {
      throw new DbError("23505", "NIK sudah dipakai akun lain");
    },
  });
  assertEquals((await json(await taken.handler(kyc()))).body.error.code, "nik_taken");
  const pending = setup({
    store_kyc: () => {
      throw new DbError("23505", "KYC sudah dikirim dan belum ditolak");
    },
  });
  assertEquals((await json(await pending.handler(kyc()))).body.error.code, "kyc_exists");
});

Deno.test("add_payout_method: name must match KYC, duplicate → account_taken, returns id + last4", async () => {
  const s = setup();
  const ok = await json(
    await s.handler(
      post({
        action: "add_payout_method",
        kind: "bank",
        bank_code: "bca",
        account_no: "888-123-4567",
        account_name: "andi saputra",
      }),
    ),
  );
  assertEquals(ok.body.data, { id: "00000000-0000-0000-0000-0000000001aa", last4: "4567" });
  const a = s.rpc.named("store_payout_method")[0].args;
  assertEquals([a.p_bank_code, a.p_last4, a.p_kind], ["BCA", "4567", "bank"]);
  assertEquals(a.p_account_no_hash, toPgBytea(await crypto.hmac("8881234567")));
  const mismatch = await json(
    await s.handler(
      post({
        action: "add_payout_method",
        kind: "bank",
        bank_code: "BCA",
        account_no: "8881234567",
        account_name: "Andi S",
      }),
    ),
  );
  assertEquals([mismatch.status, mismatch.body.error.code], [422, "name_mismatch"]);
  const noKyc = setup({ svc_kyc: () => [] });
  assertEquals(
    (await json(
      await noKyc.handler(
        post({
          action: "add_payout_method",
          kind: "bank",
          bank_code: "BCA",
          account_no: "8881234567",
          account_name: "Andi Saputra",
        }),
      ),
    )).body.error.code,
    "kyc_required",
  );
  const dup = setup({
    store_payout_method: () => {
      throw new DbError("23505", "duplicate key value violates unique constraint");
    },
  });
  assertEquals(
    (await json(
      await dup.handler(
        post({
          action: "add_payout_method",
          kind: "bank",
          bank_code: "BCA",
          account_no: "8881234567",
          account_name: "Andi Saputra",
        }),
      ),
    )).body.error.code,
    "account_taken",
  );
});

Deno.test("e-wallet numbers: +62 / 62 / 0 spellings hash the same (FR-04)", async () => {
  assertEquals(normalizeAccountNo("ewallet", "+62 812-3456-7890"), "081234567890");
  assertEquals(normalizeAccountNo("ewallet", "6281234567890"), "081234567890");
  assertEquals(normalizeAccountNo("ewallet", "081234567890"), "081234567890");
  assertEquals(
    toHex(await crypto.hmac(normalizeAccountNo("ewallet", "+6281234567890"))),
    toHex(await crypto.hmac("081234567890")),
  );
  assertEquals(normalizeLegalName("  Siti   Nur'aini  "), "Siti Nur'aini");
});

Deno.test("save_recipient + download_my_data: encrypted at rest, decrypted only for the owner, audited", async () => {
  const s = setup();
  const saved = await json(
    await s.handler(
      post({
        action: "save_recipient",
        reward_type_id: "00000000-0000-0000-0000-0000000003aa",
        data: { address: "Jl. Mawar 1", phone: "0812" },
      }),
    ),
  );
  assertEquals(saved.body.data, { recipient_ref: "00000000-0000-0000-0000-0000000002aa" });
  const stored = s.rpc.named("store_recipient")[0].args;
  const nik = await crypto.encrypt("kyc.nik", "3171011205900001");
  const acc = await crypto.encrypt("payout.account_no", "8881234567");
  const d = setup({
    svc_my_data: () => ({
      account: { id: UID, email: "a@contoh.id" },
      kyc: { legal_name: "Andi Saputra", nik_enc: toPgBytea(nik.ciphertext), enc_key_version: 1, status: "approved" },
      payout_methods: [{ id: "m1", bank_code: "BCA", account_no_enc: toPgBytea(acc.ciphertext), enc_key_version: 1 }],
      recipients: [{
        id: "r1",
        reward_type_id: "rt",
        data_enc: stored.p_data_enc,
        enc_key_version: stored.p_key_version,
      }],
      consents: [{ kind: "kyc" }],
      push_subscriptions: [],
      platform_roles: [],
    }),
  });
  const res = await json(await d.handler(post({ action: "download_my_data" })));
  assertEquals(res.body.data.kyc, { legal_name: "Andi Saputra", status: "approved", nik: "3171011205900001" });
  assertEquals(res.body.data.payout_methods, [{ id: "m1", bank_code: "BCA", account_no: "8881234567" }]);
  assertEquals(res.body.data.recipients[0].data, { address: "Jl. Mawar 1", phone: "0812" });
  assertEquals(d.rpc.named("svc_audit")[0].args, {
    p_actor: UID,
    p_action: "pii.self_export",
    p_target: `user:${UID}`,
  });
});

Deno.test("member-data: CORS only for APP_ORIGINS, unknown action rejected", async () => {
  Deno.env.set("APP_ORIGINS", "https://accounts.clipper.test,https://app.clipper.test");
  const s = setup();
  const pre = await s.handler(
    new Request("http://localhost/member-data", {
      method: "OPTIONS",
      headers: { origin: "https://accounts.clipper.test" },
    }),
  );
  assertEquals([pre.status, pre.headers.get("access-control-allow-origin")], [204, "https://accounts.clipper.test"]);
  const evil = await s.handler(
    new Request("http://localhost/member-data", { method: "OPTIONS", headers: { origin: "https://evil.test" } }),
  );
  assertEquals(evil.status, 403);
  const res = await s.handler(post({ action: "nope" }, { origin: "https://app.clipper.test" }));
  assertEquals(res.headers.get("access-control-allow-origin"), "https://app.clipper.test");
  assertEquals((await res.json()).error.code, "unknown_action");
  Deno.env.delete("APP_ORIGINS");
});
