// identity/session-handoff — app native membuka accounts./app./brand.{domain} di in-app browser yang belum punya cookie
// SSO .{domain}: sesi app dipindah lewat kode sekali pakai, bukan token di URL.
//   create (JWT user app native): next harus URL di host ACCOUNTS_URL / APP_URL / BRAND_URL. Kode = 32 byte acak
//          base64url; yang disimpan hanya sha256-nya, berlaku 60 detik, maks 10 aktif per user (api.svc_create_handoff).
//          Akun admin ditolak (AA-20: admin login terpisah di admin.{domain}, tidak memakai sesi SSO). aal tidak dinaikkan:
//          sesi web hasil tukar selalu aal1, halaman yang butuh aal2 tetap meminta MFA.
//   redeem (server accounts.{domain} route /handoff, apikey publishable saja): tukar atomik sekali pakai
//          (api.svc_redeem_handoff) → token_hash magic link (auth.admin.generateLink, tanpa email); route memanggil
//          verifyOtp sehingga cookie SSO ditulis di .{domain}.
// Kode, token_hash, dan email tidak pernah dicatat di log (wrap hanya mencatat status + kode error).
import type { Claims } from "../_shared/auth.ts";
import { b64encode, toPgBytea } from "../_shared/crypto.ts";
import { type AuthAdmin, DbError, type Rpc } from "../_shared/db.ts";
import { HttpError, okResponse, readJson, str, wrap } from "../_shared/http.ts";
import type { Links } from "../_shared/templates.ts";

export interface SessionHandoffDeps {
  verifyJwt: (req: Request) => Promise<Claims>;
  isPublishable: (req: Request) => boolean;
  rpc: Rpc;
  authAdmin: Pick<AuthAdmin, "getUser" | "magicLink">;
  links: () => Links;
  randomBytes?: (n: number) => Uint8Array;
  now?: () => number;
}

export const CODE_BYTES = 32;
const CODE_RE = /^[A-Za-z0-9_-]{43}$/;

const isAdminRole = (roles: readonly string[]) => roles.some((r) => r.startsWith("admin_"));

function b64url(u: Uint8Array): string {
  return b64encode(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function codeHash(code: string): Promise<string> {
  return toPgBytea(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code))));
}

/** next absolut (http/https) di origin accounts/app/brand; admin & host lain ditolak (anti open redirect). */
export function allowedNext(raw: string, links: Links): string {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new HttpError(400, "invalid_next", "next harus URL accounts, app, atau brand");
  }
  const origins = [links.accounts, links.app, links.brand].map((b) => new URL(b).origin);
  if ((u.protocol !== "https:" && u.protocol !== "http:") || u.username || u.password || !origins.includes(u.origin)) {
    throw new HttpError(400, "invalid_next", "next harus URL accounts, app, atau brand");
  }
  return u.toString();
}

async function create(deps: SessionHandoffDeps, req: Request, body: Record<string, unknown>) {
  const claims = await deps.verifyJwt(req);
  if (isAdminRole(claims.app_roles)) throw new HttpError(403, "admin_account", "akun admin masuk lewat admin");
  const links = deps.links();
  const next = allowedNext(str(body, "next", { max: 2000 }), links);
  // Claim app_roles bisa tertinggal ≤ 1 umur JWT setelah role admin diberikan: cek E-27 terkini juga.
  const roles = (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: claims.sub })) ?? [];
  if (isAdminRole(roles)) throw new HttpError(403, "admin_account", "akun admin masuk lewat admin");

  const code = b64url((deps.randomBytes ?? ((n) => crypto.getRandomValues(new Uint8Array(n))))(CODE_BYTES));
  try {
    await deps.rpc.invoke("svc_create_handoff", {
      p_user: claims.sub,
      p_code_hash: await codeHash(code),
      p_next: next,
    });
  } catch (err) {
    if (err instanceof DbError && err.pgCode === "54000") {
      throw new HttpError(429, "too_many_requests", "terlalu banyak permintaan, coba lagi sebentar");
    }
    throw err;
  }
  return { code, url: `${links.accounts}/handoff?code=${code}` };
}

async function redeem(deps: SessionHandoffDeps, req: Request, body: Record<string, unknown>) {
  if (!deps.isPublishable(req)) throw new HttpError(401, "unauthorized", "butuh apikey project");
  const invalid = new HttpError(400, "invalid_code", "kode tidak berlaku");
  const code = typeof body.code === "string" ? body.code : "";
  if (!CODE_RE.test(code)) throw invalid;
  const [row] = (await deps.rpc.invoke<{ user_id: string; next: string }[] | null>("svc_redeem_handoff", {
    p_code_hash: await codeHash(code),
  })) ?? [];
  if (!row) throw invalid; // tidak dikenal, sudah dipakai, atau kedaluwarsa: jawaban sama
  const roles = (await deps.rpc.invoke<string[] | null>("svc_platform_roles", { p_user: row.user_id })) ?? [];
  if (isAdminRole(roles)) throw invalid;
  const user = await deps.authAdmin.getUser(row.user_id);
  const now = (deps.now ?? Date.now)();
  if (!user?.email || (user.banned_until && Date.parse(user.banned_until) > now)) throw invalid;
  return { token_hash: await deps.authAdmin.magicLink(user.email), next: row.next };
}

export function createSessionHandoffHandler(deps: SessionHandoffDeps): (req: Request) => Promise<Response> {
  return wrap({ fn: "session-handoff", cors: true }, async (req) => {
    const body = await readJson(req, 4 * 1024);
    switch (body.action) {
      case "create":
        return okResponse(await create(deps, req, body));
      case "redeem":
        return okResponse(await redeem(deps, req, body));
      default:
        throw new HttpError(400, "unknown_action", "action tidak dikenal");
    }
  });
}
