// identity/member-data — the only writer of NIK, account numbers and reward recipient data (§15.4, C1.12, C1.13,
// C6.1, C2.4). Caller: end user with an identity JWT (browser on accounts.{domain} / app.{domain}).
// Request bodies are never logged (§15.9).
import type { Claims } from "../_shared/auth.ts";
import type { CoreBridge } from "../_shared/bridge.ts";
import { type PiiCrypto, toPgBytea } from "../_shared/crypto.ts";
import { DbError, type Rpc, type Storage } from "../_shared/db.ts";
import { action, HttpError, obj, okResponse, readJson, str, uuid, wrap } from "../_shared/http.ts";
import { assertAdultNik, todayJakarta, type Ymd } from "../_shared/nik.ts";
import { type KycRow, normalizeName } from "../_shared/payouts.ts";

export interface MemberDataDeps {
  verifyJwt: (req: Request) => Promise<Claims>;
  rpc: Rpc;
  core: () => CoreBridge;
  userRpc: (jwt: string) => Rpc;
  storage: Storage;
  crypto: () => PiiCrypto;
  today?: () => Ymd;
}

export const KYC_BUCKET = "kyc-docs";

/** KTP name: letters (any script), spaces and . , ' - ; collapsed spaces; 2–100 chars (E-05 CHECK). */
export function normalizeLegalName(raw: string): string {
  const s = raw.normalize("NFC").trim().replace(/\s+/g, " ");
  if (s.length < 2 || s.length > 100 || !/^[\p{L}\p{M}][\p{L}\p{M} .,'-]*$/u.test(s)) {
    throw new HttpError(
      400,
      "invalid_name",
      "nama hanya boleh huruf, spasi, titik, koma, apostrof, strip (2–100 karakter)",
    );
  }
  return s;
}

/**
 * Account number canonical form (input to HMAC + ciphertext). Bank: 5–20 digits. E-wallet: Indonesian mobile number,
 * "+62…"/"62…" rewritten to "0…" so the same wallet cannot be registered twice in two spellings (FR-04).
 */
export function normalizeAccountNo(kind: "bank" | "ewallet", raw: string): string {
  let d = raw.replace(/[\s.+-]/g, "");
  if (!/^\d+$/.test(d)) throw new HttpError(400, "invalid_account_no", "nomor rekening hanya angka");
  if (kind === "ewallet") {
    if (d.startsWith("62")) d = "0" + d.slice(2);
    if (!/^08\d{8,12}$/.test(d)) throw new HttpError(400, "invalid_account_no", "nomor e-wallet harus nomor HP 08…");
  } else if (d.length < 5 || d.length > 20) {
    throw new HttpError(400, "invalid_account_no", "nomor rekening 5–20 digit");
  }
  return d;
}

/** Object path inside kyc-docs must sit in the caller's own folder ({uid}/…), like the storage policy. */
export function assertOwnDocPath(uid: string, path: string): void {
  const parts = path.split("/");
  if (
    parts.length < 2 || parts[0] !== uid ||
    parts.slice(1).some((p) => p === "" || p === "." || p === ".." || !/^[A-Za-z0-9._-]{1,120}$/.test(p))
  ) {
    throw new HttpError(400, "invalid_doc_path", "foto KTP harus di folder milik sendiri");
  }
}

function recipientData(raw: unknown): Record<string, string> {
  const o = obj(raw, "data");
  const entries = Object.entries(o);
  if (entries.length === 0 || entries.length > 20) {
    throw new HttpError(400, "invalid_input", "data penerima 1–20 kolom");
  }
  const out: Record<string, string> = {};
  for (const [k, v] of entries) {
    if (!/^[a-z][a-z0-9_]{0,39}$/.test(k)) {
      throw new HttpError(400, "invalid_input", "nama kolom data penerima tidak valid");
    }
    if (typeof v !== "string" && typeof v !== "number") throw new HttpError(400, "invalid_input", `${k} harus teks`);
    const s = String(v).trim();
    if (s.length > 500) throw new HttpError(400, "invalid_input", `${k} terlalu panjang`);
    out[k] = s;
  }
  if (JSON.stringify(out).length > 4096) throw new HttpError(413, "payload_too_large", "data penerima terlalu besar");
  return out;
}

/** FR-04 (A2.1 "NIK atau rekening ganda → tolak + tandai fraud"): akun yang mencoba memakai NIK/rekening milik akun lain
 * diberi fraud flag di core → withdraw diblok sampai direview. Pemegangnya ikut di payload (tanpa PII); gagal = tidak
 * mengubah respons ke user. */
async function flagReuse(deps: MemberDataDeps, user: string, kind: "nik" | "account", args: Record<string, unknown>) {
  try {
    const [h] =
      (await deps.rpc.invoke<{ user_id: string | null; tombstone: boolean }[] | null>("svc_hash_holder", args)) ?? [];
    if (h && h.user_id === user) return; // rekening/NIK miliknya sendiri
    await deps.core().invoke("raise_fraud_flag", {
      target_type: "profile",
      target_id: user,
      signal: "FR-04",
      score: h?.tombstone ? 100 : 80,
      details: { kind, related_user_ids: h?.user_id ? [h.user_id] : [], banned_holder: h?.tombstone ?? false },
    });
  } catch {
    // flag terbuka per (target, sinyal) cukup satu; percobaan berikutnya mencoba lagi
  }
}

async function submitKyc(deps: MemberDataDeps, c: Claims, body: Record<string, unknown>) {
  const legalName = normalizeLegalName(str(body, "legal_name", { max: 200 }));
  const info = assertAdultNik(str(body, "nik", { max: 40 }), (deps.today ?? todayJakarta)());
  const docPath = str(body, "doc_path", { max: 300 });
  assertOwnDocPath(c.sub, docPath);
  if (!(await deps.storage.exists(KYC_BUCKET, docPath))) {
    throw new HttpError(422, "doc_missing", "foto KTP belum terunggah");
  }

  // UU PDP: consent for KYC processing is recorded before the data is stored (as the user, so auth.uid() applies).
  try {
    await deps.userRpc(c.token).invoke("record_consent", { p_kind: "kyc" });
  } catch {
    throw new HttpError(502, "consent_failed", "persetujuan KYC gagal dicatat, coba lagi");
  }

  const crypto = deps.crypto();
  const hash = await crypto.hmac(info.nik);
  const enc = await crypto.encrypt("kyc.nik", info.nik);
  try {
    await deps.rpc.invoke("store_kyc", {
      p_user_id: c.sub,
      p_nik_hash: toPgBytea(hash),
      p_nik_enc: toPgBytea(enc.ciphertext),
      p_nik_last4: info.nik.slice(-4),
      p_key_version: enc.version,
      p_legal_name: legalName,
      p_doc_ref: docPath,
    });
  } catch (err) {
    if (err instanceof DbError && err.pgCode === "23505") {
      if (/NIK|kyc_nik_unique/.test(err.dbMessage)) {
        await flagReuse(deps, c.sub, "nik", { p_nik_hash: toPgBytea(hash), p_bank_code: null, p_account_hash: null });
        throw new HttpError(409, "nik_taken", "NIK sudah dipakai akun lain");
      }
      throw new HttpError(409, "kyc_exists", "KYC sudah dikirim dan belum ditolak");
    }
    if (err instanceof DbError && err.pgCode === "23514") {
      throw new HttpError(422, "invalid_input", "data KYC tidak valid");
    }
    throw err;
  }
  return { status: "pending", nik_last4: info.nik.slice(-4) };
}

async function addPayoutMethod(deps: MemberDataDeps, c: Claims, body: Record<string, unknown>) {
  const kind = str(body, "kind", { pattern: /^(bank|ewallet)$/ }) as "bank" | "ewallet";
  const bankCode = str(body, "bank_code", { max: 20 }).trim().toUpperCase();
  if (!/^[A-Z0-9_]{2,20}$/.test(bankCode)) throw new HttpError(400, "invalid_input", "kode bank tidak valid");
  const accountNo = normalizeAccountNo(kind, str(body, "account_no", { max: 40 }));
  const accountName = normalizeLegalName(str(body, "account_name", { max: 200 }));

  const [kyc] = (await deps.rpc.invoke<KycRow[] | null>("svc_kyc", { p_user_ids: [c.sub] })) ?? [];
  if (!kyc || kyc.closed || kyc.status === "rejected") {
    throw new HttpError(422, "kyc_required", "lengkapi KYC dulu");
  }
  if (normalizeName(kyc.legal_name) !== normalizeName(accountName)) {
    throw new HttpError(422, "name_mismatch", "nama pemilik rekening harus sama dengan nama KYC");
  }

  const crypto = deps.crypto();
  const hash = await crypto.hmac(accountNo);
  const enc = await crypto.encrypt("payout.account_no", accountNo);
  const last4 = accountNo.slice(-4);
  let id: string;
  try {
    id = await deps.rpc.invoke<string>("store_payout_method", {
      p_user_id: c.sub,
      p_kind: kind,
      p_bank_code: bankCode,
      p_account_no_hash: toPgBytea(hash),
      p_account_no_enc: toPgBytea(enc.ciphertext),
      p_last4: last4,
      p_key_version: enc.version,
      p_account_name: accountName,
    });
  } catch (err) {
    if (err instanceof DbError) {
      if (err.pgCode === "23505") {
        await flagReuse(deps, c.sub, "account", {
          p_nik_hash: null,
          p_bank_code: bankCode,
          p_account_hash: toPgBytea(hash),
        });
        throw new HttpError(409, "account_taken", "rekening sudah dipakai akun lain");
      }
      if (err.pgCode === "22023" && /KYC dulu/.test(err.dbMessage)) {
        throw new HttpError(422, "kyc_required", "lengkapi KYC dulu");
      }
      if (err.pgCode === "22023") {
        throw new HttpError(422, "name_mismatch", "nama pemilik rekening harus sama dengan nama KYC");
      }
      if (err.pgCode === "23514") throw new HttpError(422, "invalid_input", "data rekening tidak valid");
    }
    throw err;
  }
  return { id, last4 };
}

async function saveRecipient(deps: MemberDataDeps, c: Claims, body: Record<string, unknown>) {
  const rewardTypeId = uuid(body, "reward_type_id");
  const data = recipientData(body.data);
  const enc = await deps.crypto().encrypt("recipient.data", JSON.stringify(data));
  const id = await deps.rpc.invoke<string>("store_recipient", {
    p_user_id: c.sub,
    p_reward_type_id: rewardTypeId,
    p_data_enc: toPgBytea(enc.ciphertext),
    p_key_version: enc.version,
  });
  return { recipient_ref: id };
}

interface MyData {
  account: Record<string, unknown> | null;
  kyc: (Record<string, unknown> & { nik_enc: string | null; enc_key_version: number | null }) | null;
  payout_methods: (Record<string, unknown> & { account_no_enc: string | null; enc_key_version: number | null })[];
  recipients: (Record<string, unknown> & { data_enc: string; enc_key_version: number })[];
  consents: unknown[];
  push_subscriptions: unknown[];
  platform_roles: unknown[];
}

async function downloadMyData(deps: MemberDataDeps, c: Claims) {
  const d = await deps.rpc.invoke<MyData>("svc_my_data", { p_user: c.sub });
  const crypto = deps.crypto();
  let kyc: Record<string, unknown> | null = null;
  if (d.kyc) {
    const { nik_enc, enc_key_version, ...rest } = d.kyc;
    kyc = {
      ...rest,
      nik: nik_enc && enc_key_version ? await crypto.decryptPg("kyc.nik", nik_enc, enc_key_version) : null,
    };
  }
  const payoutMethods = await Promise.all(
    d.payout_methods.map(async ({ account_no_enc, enc_key_version, ...rest }) => ({
      ...rest,
      account_no: account_no_enc && enc_key_version
        ? await crypto.decryptPg("payout.account_no", account_no_enc, enc_key_version)
        : null,
    })),
  );
  const recipients = await Promise.all(d.recipients.map(async ({ data_enc, enc_key_version, ...rest }) => ({
    ...rest,
    data: JSON.parse(await crypto.decryptPg("recipient.data", data_enc, enc_key_version)),
  })));
  await deps.rpc.invoke("svc_audit", { p_actor: c.sub, p_action: "pii.self_export", p_target: `user:${c.sub}` });
  return {
    generated_at: new Date().toISOString(),
    source: "identity",
    account: d.account,
    kyc,
    payout_methods: payoutMethods,
    recipients,
    consents: d.consents,
    push_subscriptions: d.push_subscriptions,
    platform_roles: d.platform_roles,
  };
}

export function createMemberDataHandler(deps: MemberDataDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "member-data", cors: true }, async (req) => {
    const claims = await deps.verifyJwt(req);
    const body = await readJson(req, 16 * 1024);
    switch (action(body)) {
      case "submit_kyc":
        return okResponse(await submitKyc(deps, claims, body));
      case "add_payout_method":
        return okResponse(await addPayoutMethod(deps, claims, body));
      case "save_recipient":
        return okResponse(await saveRecipient(deps, claims, body));
      case "download_my_data":
        return okResponse(await downloadMyData(deps, claims));
      default:
        throw new HttpError(400, "unknown_action", "action tidak dikenal");
    }
  });
}
