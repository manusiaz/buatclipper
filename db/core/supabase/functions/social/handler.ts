// core/social (user JWT identity): connect OAuth sosmed, daftar video setelah claim, submit video (E-12).
// Aksi POST {action, …}: authorize | connect | list_videos | submit. CORS hanya origin di APP_ORIGINS.
import { type User, verifyUserJwt } from "../_shared/auth.ts";
import { type Rpc, RpcError, serviceRpc, userClient } from "../_shared/db.ts";
import { corsHeaders, envList, errorResponse, HttpError, json, randomToken, readJson } from "../_shared/http.ts";
import {
  AdapterError,
  adapterFor,
  ensureFresh,
  isPlatform,
  parseToken,
  pkcePair,
  type Platform,
  type PlatformAdapter,
  platformFlags,
  Retryable,
  type StoredToken,
  TokenExpired,
  type Video,
} from "../_shared/social/mod.ts";

export interface Claim {
  id: string;
  campaign_id: string;
  user_id: string;
  status: string;
  created_at: string;
}

export interface AccountRow {
  id: string;
  user_id: string;
  platform: Platform;
  external_id: string;
  handle: string;
  status: string;
  token: string | null;
}

export interface SocialDeps {
  auth: (req: Request) => Promise<User>;
  rpc: Rpc;
  adapter: (p: Platform) => PlatformAdapter;
  flags: () => Promise<Record<string, boolean>>;
  getClaim: (user: User, claimId: string) => Promise<Claim | null>;
  missingTags: (user: User, campaignId: string, caption: string) => Promise<string[] | null>;
  redirectAllowlist: string[];
  origins: string[];
}

/** Kode error worker_create_submission (P0001, "kode" atau "kode:detail"). */
export const SUBMIT_ERRORS = [
  "claim_not_open",
  "not_your_claim",
  "account_not_yours",
  "platform_not_allowed",
  "posted_before_claim",
  "missing_tags",
  "duration_out_of_range",
  "already_submitted",
  "reused_video",
  "campaign_closed",
  "profile_inactive",
  "account_inactive",
  "invalid", // invalid:url
] as const;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function str(
  body: Record<string, unknown>,
  key: string,
  opts: { optional?: boolean; max?: number; uuid?: boolean } = {},
): string {
  const v = body[key];
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return "";
    throw new HttpError(400, "bad_request", `${key} wajib`);
  }
  if (typeof v !== "string" || v.length > (opts.max ?? 2048) || (opts.uuid && !UUID.test(v))) {
    throw new HttpError(400, "bad_request", `${key} tidak valid`);
  }
  return v;
}

/** RPC error → kode bisnis. Pesan P0001 dari fungsi SQL berbentuk "kode" atau "kode:detail". */
export function mapRpcError(e: unknown, known: readonly string[]): HttpError {
  if (!(e instanceof RpcError)) throw e;
  const m = /^([a-z_]+)(?::\s*(.*))?$/s.exec(e.message.trim());
  if (m && known.includes(m[1])) {
    const detail = m[1] === "missing_tags" && m[2]
      ? m[2].replace(/^[{[]|[}\]]$/g, "").split(",").map((s) => s.trim().replace(/^"|"$/g, "")).filter(Boolean)
      : m[2] || undefined;
    return new HttpError(422, m[1], m[1], detail);
  }
  if (known.includes("account_limit") && (e.code === "23514" || /account_limit|maksimal/.test(e.message))) {
    return new HttpError(422, "account_limit");
  }
  if (known.includes("social_taken") && (e.code === "23505" || /social_taken/.test(e.message))) {
    return new HttpError(422, "social_taken");
  }
  console.error("rpc error", e.fn, e.code, e.message);
  return new HttpError(500, "internal", "internal error");
}

/** Error adapter → respons. TokenExpired saat memakai token tersimpan = akun perlu reconnect. */
function mapAdapterError(e: unknown): never {
  if (e instanceof AdapterError) throw new HttpError(422, e.code, e.message, e.detail);
  if (e instanceof Retryable) {
    throw new HttpError(503, "platform_unavailable", "API platform sedang bermasalah, coba lagi");
  }
  throw e;
}

export function createSocialHandler(deps: SocialDeps): (req: Request) => Promise<Response> {
  async function enabled(p: Platform): Promise<void> {
    let flags: Record<string, boolean>;
    try {
      flags = await deps.flags();
    } catch (e) {
      console.error("flags", e);
      throw new HttpError(503, "settings_unavailable");
    }
    if (flags[p] !== true) throw new HttpError(422, "platform_disabled");
  }

  function redirect(body: Record<string, unknown>): string {
    const uri = str(body, "redirect_uri");
    if (!deps.redirectAllowlist.includes(uri)) throw new HttpError(400, "redirect_not_allowed");
    return uri;
  }

  /** Akun milik user + token segar. Token kedaluwarsa → status expired + 409 token_expired (UI: Reconnect). */
  async function account(
    user: User,
    accountId: string,
  ): Promise<{ acct: AccountRow; adapter: PlatformAdapter; token: StoredToken }> {
    const acct = await deps.rpc<AccountRow | null>("worker_account_token", { p_account: accountId });
    if (!acct || acct.user_id !== user.id) throw new HttpError(422, "account_not_yours");
    await enabled(acct.platform);
    const adapter = deps.adapter(acct.platform);
    const stored = parseToken(acct.token);
    if (acct.status !== "verified" || !stored) throw new HttpError(409, "token_expired", "hubungkan ulang akun");
    try {
      return { acct, adapter, token: await ensureFresh(adapter, stored, acct.id, deps.rpc) };
    } catch (e) {
      return await expired(e, acct.id);
    }
  }

  async function expired(e: unknown, accountId: string): Promise<never> {
    if (e instanceof TokenExpired) {
      await deps.rpc("worker_account_status", { p_account: accountId, p_status: e.revoked ? "revoked" : "expired" });
      throw new HttpError(409, "token_expired", "hubungkan ulang akun");
    }
    return mapAdapterError(e);
  }

  const actions: Record<string, (user: User, body: Record<string, unknown>) => Promise<unknown>> = {
    async authorize(_user, body) {
      const platform = body.platform;
      if (!isPlatform(platform)) throw new HttpError(400, "bad_request", "platform tidak dikenal");
      await enabled(platform);
      const redirectUri = redirect(body);
      const adapter = deps.adapter(platform);
      const state = randomToken(24);
      if (adapter.pkce === "none") return { url: adapter.authorizeUrl(redirectUri, state), state };
      const { verifier, challenge } = await pkcePair();
      return { url: adapter.authorizeUrl(redirectUri, state, challenge), state, code_verifier: verifier };
    },

    async connect(user, body) {
      const platform = body.platform;
      if (!isPlatform(platform)) throw new HttpError(400, "bad_request", "platform tidak dikenal");
      await enabled(platform);
      const redirectUri = redirect(body);
      const code = str(body, "code");
      const verifier = str(body, "code_verifier", { optional: true, max: 128 }) || undefined;
      const pageId = str(body, "page_id", { optional: true, max: 64 }) || undefined;
      const adapter = deps.adapter(platform);
      let token: StoredToken;
      let prof;
      try {
        token = await adapter.exchangeCode(code, redirectUri, verifier, { pageId });
        prof = await adapter.profile(token);
      } catch (e) {
        if (e instanceof TokenExpired) throw new HttpError(422, "oauth_failed", e.message);
        return mapAdapterError(e);
      }
      token = { ...token, meta: { ...token.meta, ...prof.tokenMeta } };
      let accountId: string;
      try {
        accountId = await deps.rpc<string>("worker_upsert_social_account", {
          p_user: user.id,
          p_platform: platform,
          p_external_id: prof.externalId,
          p_handle: prof.handle,
          p_followers: prof.followers,
          p_platform_created_at: prof.createdAt ?? null,
          p_token: JSON.stringify(token),
        });
      } catch (e) {
        throw mapRpcError(e, ["social_taken", "account_limit", "profile_inactive"]);
      }
      return { account_id: accountId, platform, handle: prof.handle, followers: prof.followers };
    },

    async list_videos(user, body) {
      const accountId = str(body, "account_id", { uuid: true });
      const claimId = str(body, "claim_id", { uuid: true });
      const claim = await deps.getClaim(user, claimId);
      if (!claim || claim.user_id !== user.id) throw new HttpError(422, "not_your_claim");
      const { acct, adapter, token } = await account(user, accountId);
      let videos: Video[];
      try {
        videos = await adapter.listVideos(token, claim.created_at);
      } catch (e) {
        return await expired(e, acct.id);
      }
      const out: (Video & { missing_tags: string[] | null })[] = [];
      for (let i = 0; i < videos.length; i += 8) {
        const part = videos.slice(i, i + 8);
        const tags = await Promise.all(part.map((v) => deps.missingTags(user, claim.campaign_id, v.caption)));
        part.forEach((v, j) => out.push({ ...v, missing_tags: tags[j] }));
      }
      return { platform: acct.platform, videos: out };
    },

    async submit(user, body) {
      const claimId = str(body, "claim_id", { uuid: true });
      const accountId = str(body, "account_id", { uuid: true });
      const ref = str(body, "post_id", { optional: true, max: 64 }) || str(body, "url", { optional: true });
      if (!ref) throw new HttpError(400, "bad_request", "post_id atau url wajib");
      const { acct, adapter, token } = await account(user, accountId);
      let video: Video;
      try {
        video = await adapter.getPost(token, ref); // kepemilikan: post harus milik akun token
      } catch (e) {
        return await expired(e, acct.id);
      }
      try {
        return await deps.rpc<{ submission_id: string; status: string }>("worker_create_submission", {
          p_user: user.id,
          p_claim: claimId,
          p_account: acct.id,
          p_post_id: video.postId,
          p_url: video.url,
          p_posted_at: video.postedAt,
          p_caption: video.caption,
          p_duration_sec: video.durationSec,
        });
      } catch (e) {
        throw mapRpcError(e, SUBMIT_ERRORS);
      }
    },
  };

  return async (req: Request) => {
    const cors = corsHeaders(req, deps.origins);
    if (req.method === "OPTIONS") return new Response(null, { status: cors.ok ? 204 : 403, headers: cors.headers });
    if (!cors.ok) return json(403, { error: "origin_not_allowed" }, cors.headers);
    try {
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
      const user = await deps.auth(req);
      const body = await readJson(req);
      const fn = typeof body.action === "string" ? actions[body.action] : undefined;
      if (!fn || !Object.hasOwn(actions, body.action as string)) throw new HttpError(400, "bad_action");
      return json(200, await fn(user, body), cors.headers);
    } catch (e) {
      return errorResponse(e, cors.headers);
    }
  };
}

export function defaultSocialDeps(): SocialDeps {
  return {
    auth: (req) => verifyUserJwt(req),
    rpc: serviceRpc(),
    adapter: (p) => adapterFor(p),
    flags: () => platformFlags(),
    async getClaim(user, claimId) {
      const { data, error } = await userClient(user.jwt).from("claims").select(
        "id,campaign_id,user_id,status,created_at",
      )
        .eq("id", claimId).eq("user_id", user.id).maybeSingle();
      if (error) throw new RpcError("claims", error.code ?? "", error.message);
      return data as Claim | null;
    },
    async missingTags(user, campaignId, caption) {
      const { data, error } = await userClient(user.jwt).rpc("missing_brief_tags", {
        p_campaign: campaignId,
        p_caption: caption,
      });
      if (error) throw new RpcError("missing_brief_tags", error.code ?? "", error.message);
      return data as string[] | null;
    },
    redirectAllowlist: envList("SOCIAL_REDIRECT_ALLOWLIST"),
    origins: envList("APP_ORIGINS"),
  };
}
