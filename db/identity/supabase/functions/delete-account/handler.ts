// identity/delete-account — alur 7 (UU PDP right to erasure, C2.4). Caller: the user (identity JWT).
// 1. core close_account (refuses while balance/payouts are open; stops tracking, deletes social tokens, anonymizes E-01)
// 2. retention decision: blocked = Auth ban active; retain_until = today + 10 years when KYC was approved (tax records,
//    UU KUP Pasal 28 ayat 11 — duration to be validated by the tax consultant)
// 3. api.svc_close_member → KYC/account rows become tombstones or are deleted (constraints E-05/E-16)
// 4. KTP photos in kyc-docs/{uid}/ removed
// 5. auth.admin.deleteUser → consents, recipients, push subscriptions, roles cascade; sessions end.
// Every step is idempotent, so a retry after a partial failure completes the deletion.
import type { Claims } from "../_shared/auth.ts";
import type { CoreBridge } from "../_shared/bridge.ts";
import type { AuthAdmin, Rpc, Storage } from "../_shared/db.ts";
import { errorResponse, HttpError, okResponse, readJson, wrap } from "../_shared/http.ts";
import { todayJakarta, type Ymd } from "../_shared/nik.ts";
import type { KycRow } from "../_shared/payouts.ts";

export const TAX_RETENTION_YEARS = 10;

export interface DeleteAccountDeps {
  verifyJwt: (req: Request) => Promise<Claims>;
  rpc: Rpc;
  core: () => CoreBridge;
  storage: Storage;
  authAdmin: AuthAdmin;
  now?: () => Date;
}

export function retainUntil(today: Ymd, years = TAX_RETENTION_YEARS): string {
  const y = today.y + years;
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const d = today.m === 2 && today.d === 29 && !leap ? 28 : today.d;
  return `${y}-${String(today.m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

export function createDeleteAccountHandler(deps: DeleteAccountDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "delete-account", cors: true }, async (req) => {
    const claims = await deps.verifyJwt(req);
    const body = await readJson(req, 4 * 1024);
    if (body.confirm !== true) {
      throw new HttpError(400, "confirm_required", 'kirim {"confirm": true} untuk menghapus akun');
    }
    const uid = claims.sub;
    const now = (deps.now ?? (() => new Date()))();

    const roles = (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: uid })) ?? [];
    if (roles.length > 0) throw new HttpError(409, "admin_account", "akun admin dihapus lewat admin_super");

    const closed = await deps.core().invoke<{ ok: boolean; reason?: string }>("close_account", { user_id: uid });
    if (!closed?.ok) {
      const reason = typeof closed?.reason === "string" && /^[a-z_]{1,64}$/.test(closed.reason)
        ? closed.reason
        : "refused";
      return errorResponse(409, reason, "akun belum bisa dihapus: selesaikan saldo atau payout yang berjalan dulu");
    }

    const user = await deps.authAdmin.getUser(uid);
    const blocked = !!user?.banned_until && Date.parse(user.banned_until) > now.getTime();
    const [kyc] = (await deps.rpc.invoke<KycRow[] | null>("svc_kyc", { p_user_ids: [uid] })) ?? [];
    const retain = kyc && !kyc.closed && kyc.status === "approved" ? retainUntil(todayJakarta(now)) : null;

    const result = await deps.rpc.invoke<Record<string, unknown>>("svc_close_member", {
      p_user: uid,
      p_blocked: blocked,
      p_retain_until: retain,
    });
    const docs = await deps.storage.listAll("kyc-docs", uid);
    if (docs.length) await deps.storage.remove("kyc-docs", docs);
    await deps.authAdmin.deleteUser(uid);
    return okResponse({ ok: true, blocked, retain_until: retain, identity: result, kyc_docs_removed: docs.length });
  });
}
