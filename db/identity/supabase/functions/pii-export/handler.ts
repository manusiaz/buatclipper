// identity/pii-export — the only place batch account numbers and recipient data are decrypted for people (alur 3, 9;
// J-A3, J-A5). Caller: admin JWT with aal2; role re-checked against E-27. Every export is written to E-24 via svc_audit.
// Files go to private buckets; the caller gets a 15-minute signed URL. Request bodies are never logged (§15.9).
import { type AdminRole, type Claims, requireAdmin, requireAdminFresh } from "../_shared/auth.ts";
import type { CoreBridge } from "../_shared/bridge.ts";
import type { PiiCrypto } from "../_shared/crypto.ts";
import { toCsv } from "../_shared/csv.ts";
import { type Rpc, rpcByIds, type Storage } from "../_shared/db.ts";
import { action, HttpError, isUuid, obj, okResponse, readJson, str, uuid, wrap } from "../_shared/http.ts";
import {
  type HoldReason,
  holdReason,
  type KycRow,
  type MethodRow,
  netAmount,
  type PayoutRef,
} from "../_shared/payouts.ts";

export const SIGNED_URL_TTL_S = 900;
export const EXPORT_BUCKET = "pii-exports";
export const PROOF_BUCKET = "payout-proofs";

export interface PiiExportDeps {
  verifyJwt: (req: Request) => Promise<Claims>;
  rpc: Rpc;
  core: () => CoreBridge;
  storage: Storage;
  crypto: () => PiiCrypto;
  now?: () => Date;
}

type Actor = { id: string };

interface CoreBatch {
  batch: { id: string; status: string; created_by: string; approved_by: string | null };
  payouts: PayoutRef[];
}

const te = new TextEncoder();

async function audit(deps: PiiExportDeps, actor: Actor, act: string, target: string, after: Record<string, unknown>) {
  await deps.rpc.invoke("svc_audit", { p_actor: actor.id, p_action: act, p_target: target, p_after: after });
}

async function publish(deps: PiiExportDeps, path: string, csv: string): Promise<{ file_ref: string; url: string }> {
  await deps.storage.upload(EXPORT_BUCKET, path, te.encode(csv), "text/csv", true);
  const url = await deps.storage.signedUrl(EXPORT_BUCKET, path, SIGNED_URL_TTL_S);
  return { file_ref: `${EXPORT_BUCKET}/${path}`, url };
}

// ---- payout_csv (alur 3, A3.3) --------------------------------------------------------------------------------------

export async function exportPayouts(deps: PiiExportDeps, actor: Actor, batchId: string) {
  const core = deps.core();
  const data = await core.invoke<CoreBatch>("get_batch", { batch_id: batchId });
  const batch = data?.batch;
  const payouts = Array.isArray(data?.payouts) ? data.payouts : [];
  if (!batch || batch.id !== batchId) throw new HttpError(404, "batch_not_found", "batch tidak ditemukan");
  // Identity decrypts only batches approved by a second person (approved_by ≠ created_by).
  if (
    !["approved", "exported"].includes(batch.status) || !batch.approved_by || batch.approved_by === batch.created_by
  ) {
    throw new HttpError(409, "batch_not_approved", "batch belum disetujui orang kedua");
  }
  // Sudah diekspor: link baru untuk berkas yang sama (tanpa dekripsi ulang); tetap tercatat audit.
  if (batch.status === "exported") {
    const path = `payouts/${batchId}.csv`;
    if (!(await deps.storage.exists(EXPORT_BUCKET, path))) {
      throw new HttpError(404, "file_missing", "berkas ekspor tidak ditemukan");
    }
    const url = await deps.storage.signedUrl(EXPORT_BUCKET, path, SIGNED_URL_TTL_S);
    await audit(deps, actor, "pii.export_payouts", `batch:${batchId}`, {
      resign: true,
      file_ref: `${EXPORT_BUCKET}/${path}`,
    });
    return { url, expires_in: SIGNED_URL_TTL_S, file_ref: `${EXPORT_BUCKET}/${path}`, rows: 0, held: [] };
  }

  const methods = new Map(
    (await rpcByIds<MethodRow>(deps.rpc, "svc_payout_methods", "p_ids", payouts.map((p) => p.method_id)))
      .map((m) => [m.id, m]),
  );
  const kycs = new Map(
    (await rpcByIds<KycRow>(deps.rpc, "svc_kyc", "p_user_ids", payouts.map((p) => p.user_id)))
      .filter((k) => !k.closed)
      .map((k) => [k.user_id, k]),
  );

  const crypto = deps.crypto();
  const held: { payout_id: string; reason: HoldReason | "duplicate_payout" }[] = [];
  const rows: string[][] = [];
  const seen = new Set<string>();
  for (const p of payouts) {
    if (seen.has(p.id)) {
      held.push({ payout_id: p.id, reason: "duplicate_payout" });
      continue;
    }
    seen.add(p.id);
    const m = methods.get(p.method_id);
    const reason = holdReason(p, m, kycs.get(p.user_id));
    if (reason) {
      held.push({ payout_id: p.id, reason });
      continue;
    }
    const accountNo = await crypto.decryptPg("payout.account_no", m!.account_no_enc!, m!.enc_key_version!);
    rows.push([p.id, m!.bank_code, accountNo, m!.account_name!, netAmount(p)]);
  }

  const csv = toCsv(["payout_id", "bank_code", "account_no", "account_name", "amount"], rows);
  const { file_ref, url } = await publish(deps, `payouts/${batchId}.csv`, csv);
  await audit(deps, actor, "pii.export_payouts", `batch:${batchId}`, {
    rows: rows.length,
    held: held.length,
    file_ref,
  });
  await core.invoke("attach_export", { batch_id: batchId, file_ref, held });
  return { url, expires_in: SIGNED_URL_TTL_S, file_ref, rows: rows.length, held };
}

// ---- upload_proof (alur 9, A3.4 / A3.6) -----------------------------------------------------------------------------

const PROOF_TYPES: Record<string, { ext: string; magic: number[] }> = {
  "application/pdf": { ext: "pdf", magic: [0x25, 0x50, 0x44, 0x46] }, // %PDF
  "image/jpeg": { ext: "jpg", magic: [0xff, 0xd8, 0xff] },
  "image/png": { ext: "png", magic: [0x89, 0x50, 0x4e, 0x47] },
};
export const MAX_PROOF_BYTES = 10 * 1024 * 1024; // bucket payout-proofs file_size_limit

function decodeBase64(s: string): Uint8Array {
  try {
    const bin = atob(s.replace(/\s+/g, ""));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    throw new HttpError(400, "invalid_input", "content_base64 tidak valid");
  }
}

export async function uploadProof(deps: PiiExportDeps, actor: Actor, body: Record<string, unknown>) {
  const target = str(body, "target", { pattern: /^(batch|refund)$/ }) as "batch" | "refund";
  const id = uuid(body, "id");
  const filename = str(body, "filename", { max: 200 });
  const contentType = str(body, "content_type", { max: 60 });
  const type = PROOF_TYPES[contentType];
  if (!type) throw new HttpError(415, "unsupported_type", "bukti harus PDF, JPEG, atau PNG");
  const bytes = decodeBase64(str(body, "content_base64", { max: 15 * 1024 * 1024 }));
  if (bytes.length === 0 || bytes.length > MAX_PROOF_BYTES) {
    throw new HttpError(413, "payload_too_large", "bukti maksimal 10 MB");
  }
  if (!type.magic.every((b, i) => bytes[i] === b)) {
    throw new HttpError(415, "unsupported_type", "isi berkas tidak sesuai tipe");
  }

  const stem =
    filename.replace(/\.[A-Za-z0-9]{1,5}$/, "").replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) ||
    "bukti";
  const stamp = (deps.now ?? (() => new Date()))().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const path = `${target}/${id}/${stamp}-${stem}.${type.ext}`;
  await deps.storage.upload(PROOF_BUCKET, path, bytes, contentType, false);
  const proofRef = `${PROOF_BUCKET}/${path}`;
  await audit(deps, actor, "pii.upload_proof", `${target}:${id}`, { proof_ref: proofRef, bytes: bytes.length });
  await deps.core().invoke("attach_proof", { target, id, proof_ref: proofRef });
  return { proof_ref: proofRef };
}

// ---- pph21 (alur 9, §5.4) -----------------------------------------------------------------------------------------

function isoDate(o: Record<string, unknown>, key: string): string {
  const v = str(o, key, { pattern: /^\d{4}-\d{2}-\d{2}$/ });
  const d = new Date(`${v}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== v) {
    throw new HttpError(400, "invalid_input", `${key} bukan tanggal`);
  }
  return v;
}

/** Recap of gross payments per person with NIK + KTP name. No tax is computed: rates are the finance/tax team's call. */
export async function exportPph21(deps: PiiExportDeps, actor: Actor, body: Record<string, unknown>) {
  const from = isoDate(body, "from");
  const to = isoDate(body, "to");
  const days = (Date.parse(to) - Date.parse(from)) / 86_400_000;
  if (days < 0 || days > 366) throw new HttpError(400, "invalid_range", "rentang tanggal 0–366 hari");

  const recap = await deps.core().invoke<{ user_id: string; gross: string | number }[]>("pph21", { from, to });
  const users = (recap ?? []).filter((r) => isUuid(r.user_id));
  const kycs = new Map(
    (await rpcByIds<KycRow>(deps.rpc, "svc_kyc", "p_user_ids", users.map((r) => r.user_id))).map((k) => [k.user_id, k]),
  );
  const crypto = deps.crypto();
  const missing: string[] = [];
  const rows: string[][] = [];
  for (const r of users) {
    const k = kycs.get(r.user_id);
    let nik = "";
    if (k?.nik_enc && k.enc_key_version) nik = await crypto.decryptPg("kyc.nik", k.nik_enc, k.enc_key_version);
    else missing.push(r.user_id);
    rows.push([r.user_id, k?.legal_name ?? "", nik, String(r.gross)]);
  }
  const csv = toCsv(["user_id", "legal_name", "nik", "gross"], rows);
  const { file_ref, url } = await publish(deps, `pph21/${from}_${to}.csv`, csv);
  await audit(deps, actor, "pii.export_tax", `pph21:${from}_${to}`, {
    rows: rows.length,
    missing_kyc: missing.length,
    file_ref,
  });
  return { url, expires_in: SIGNED_URL_TTL_S, file_ref, rows: rows.length, missing_kyc: missing };
}

// ---- recipients_csv (alur 3 pattern, J-A5) ------------------------------------------------------------------------

interface CoreFulfillment {
  id: string;
  user_id: string;
  amount: string | number;
  recipient: Record<string, unknown> | null;
  recipient_ref: string | null;
}

interface RecipientRow {
  id: string;
  user_id: string;
  reward_type_id: string;
  data_enc: string;
  enc_key_version: number;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  }));
  return out;
}

/** Recipient data goes to the brand only for users with an active share_with_brand consent (E-28, §16). */
export async function exportRecipients(deps: PiiExportDeps, actor: Actor, rewardTypeId: string) {
  const list = (await deps.core().invoke<CoreFulfillment[]>("fulfillment_export", { reward_type_id: rewardTypeId })) ??
    [];
  const userIds = [...new Set(list.map((f) => f.user_id))];
  const consent = new Map<string, boolean>(
    await mapLimit(
      userIds,
      8,
      async (u) =>
        [u, await deps.rpc.invoke<boolean>("svc_has_consent", { p_user: u, p_kind: "share_with_brand" })] as [
          string,
          boolean,
        ],
    ),
  );
  const refs = list.map((f) => f.recipient_ref).filter((r): r is string => isUuid(r));
  const recipients = new Map(
    (await rpcByIds<RecipientRow>(deps.rpc, "svc_recipients", "p_ids", refs)).map((r) => [r.id, r]),
  );

  const crypto = deps.crypto();
  const skipped: { fulfillment_id: string; reason: string }[] = [];
  const records: { id: string; amount: string; fields: Record<string, string> }[] = [];
  for (const f of list) {
    if (!consent.get(f.user_id)) {
      skipped.push({ fulfillment_id: f.id, reason: "no_consent" });
      continue;
    }
    const fields: Record<string, string> = {};
    for (const [k, v] of Object.entries(obj(f.recipient ?? {}, "recipient"))) {
      if (typeof v === "string" || typeof v === "number") fields[k] = String(v);
    }
    if (f.recipient_ref) {
      const r = recipients.get(f.recipient_ref);
      if (!r) {
        skipped.push({ fulfillment_id: f.id, reason: "recipient_missing" });
        continue;
      }
      if (r.user_id !== f.user_id || r.reward_type_id !== rewardTypeId) {
        skipped.push({ fulfillment_id: f.id, reason: "recipient_mismatch" });
        continue;
      }
      const data = JSON.parse(await crypto.decryptPg("recipient.data", r.data_enc, r.enc_key_version)) as Record<
        string,
        string
      >;
      Object.assign(fields, data);
    }
    records.push({ id: f.id, amount: String(f.amount), fields });
  }

  const keys = [...new Set(records.flatMap((r) => Object.keys(r.fields)))].sort();
  const csv = toCsv(
    ["fulfillment_id", "amount", ...keys],
    records.map((r) => [r.id, r.amount, ...keys.map((k) => r.fields[k] ?? "")]),
  );
  const stamp = (deps.now ?? (() => new Date()))().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  const { file_ref, url } = await publish(deps, `recipients/${rewardTypeId}/${stamp}.csv`, csv);
  await audit(deps, actor, "pii.export_recipients", `reward_type:${rewardTypeId}`, {
    rows: records.length,
    skipped: skipped.length,
    file_ref,
  });
  return { url, expires_in: SIGNED_URL_TTL_S, file_ref, rows: records.length, skipped };
}

// ---- entry ----------------------------------------------------------------------------------------------------------

const ROLES: Record<string, readonly AdminRole[]> = {
  payout_csv: ["admin_finance"],
  upload_proof: ["admin_finance"],
  pph21: ["admin_finance"],
  recipients_csv: ["admin_finance", "admin_ops"],
};

export function createPiiExportHandler(deps: PiiExportDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "pii-export", cors: true }, async (req) => {
    const claims = await deps.verifyJwt(req);
    requireAdmin(claims, ["admin_finance", "admin_ops"]); // cheap claim gate before reading a large body
    const body = await readJson(req, 16 * 1024 * 1024);
    const act = action(body);
    const roles = ROLES[act];
    if (!roles) throw new HttpError(400, "unknown_action", "action tidak dikenal");
    await requireAdminFresh(
      claims,
      roles,
      async (u) => (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: u })) ?? [],
    );
    const actor = { id: claims.sub };
    switch (act) {
      case "payout_csv":
        return okResponse(await exportPayouts(deps, actor, uuid(body, "batch_id")));
      case "upload_proof":
        return okResponse(await uploadProof(deps, actor, body));
      case "pph21":
        return okResponse(await exportPph21(deps, actor, body));
      default:
        return okResponse(await exportRecipients(deps, actor, uuid(body, "reward_type_id")));
    }
  });
}
