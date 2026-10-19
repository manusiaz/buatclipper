// TikTok Login Kit v2 + Display API (open.tiktokapis.com/v2). Token akses 24 jam, refresh ±365 hari.
// /v2/video/query/ memverifikasi video milik user token dan menerima maks 20 video_ids per panggilan.
import { defaultHttp, type Fetch, form, type Http, type Json, oauthFailed, qs, request } from "./net.ts";
import {
  AdapterError,
  chunk,
  expiresAt,
  type MetricResult,
  type PlatformAdapter,
  type Profile,
  requireScopes,
  Retryable,
  type StoredToken,
  toInt,
  TokenExpired,
  type Video,
} from "./types.ts";

export const TIKTOK = {
  authorize: "https://www.tiktok.com/v2/auth/authorize/",
  api: "https://open.tiktokapis.com/v2",
  scopes: ["user.info.basic", "user.info.profile", "user.info.stats", "video.list"],
  videoFields: "id,create_time,cover_image_url,share_url,video_description,title,duration,view_count,like_count,comment_count,share_count",
  userFields: "open_id,union_id,display_name,username,follower_count",
  queryMax: 20,
  listMax: 20,
} as const;

// Error Display API: {error:{code,message,log_id}}; error.code "ok" = sukses.
function tiktokError(status: number, body: Json): Error {
  const code = String(body?.error?.code ?? body?.error ?? "");
  const msg = String(body?.error?.message ?? body?.error_description ?? `HTTP ${status}`);
  if (code === "access_token_invalid" || code === "invalid_grant" || status === 401) {
    return new TokenExpired(msg, code === "scope_not_authorized");
  }
  if (code === "scope_not_authorized" || code === "scope_permission_missed") return new TokenExpired(msg, true);
  if (code === "rate_limit_exceeded" || code === "internal_error" || status === 429 || status >= 500) return new Retryable(msg);
  return new AdapterError("api_error", msg, { code });
}

function videoIdFrom(input: string): string | null {
  const s = input.trim();
  if (/^\d{5,25}$/.test(s)) return s;
  const m = /tiktok\.com\/.*\/(?:video|photo)\/(\d{5,25})/.exec(s);
  return m ? m[1] : null;
}

export function createTikTok(cfg: { clientKey: string; clientSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const auth = (t: StoredToken) => ({ authorization: `Bearer ${t.access_token}` });

  async function api(t: StoredToken, path: string, fields: string, body?: unknown): Promise<Json> {
    const out = await request(
      http,
      qs(`${TIKTOK.api}${path}`, { fields }),
      body === undefined
        ? { headers: auth(t) }
        : { method: "POST", headers: { ...auth(t), "content-type": "application/json" }, body: JSON.stringify(body) },
      tiktokError,
    );
    if (out?.error?.code && out.error.code !== "ok") throw tiktokError(200, out);
    return out;
  }

  async function token(params: Record<string, string | undefined>, prev?: StoredToken): Promise<StoredToken> {
    const out = await request(http, `${TIKTOK.api}/oauth/token/`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "cache-control": "no-cache" },
      body: form({ client_key: cfg.clientKey, client_secret: cfg.clientSecret, ...params }),
    }, tiktokError);
    if (!out.access_token) throw tiktokError(400, out);
    return {
      v: 1,
      access_token: out.access_token,
      refresh_token: out.refresh_token ?? prev?.refresh_token ?? null,
      expires_at: expiresAt(out.expires_in),
      refresh_expires_at: expiresAt(out.refresh_expires_in) ?? prev?.refresh_expires_at ?? null,
      scope: out.scope ?? prev?.scope ?? null,
      meta: { ...prev?.meta, open_id: out.open_id ?? prev?.meta?.open_id ?? "" },
    };
  }

  const toVideo = (v: Json, t: StoredToken): Video => ({
    postId: String(v.id),
    url: v.share_url ?? `https://www.tiktok.com/@${t.meta?.username ?? ""}/video/${v.id}`,
    caption: v.video_description ?? v.title ?? "",
    postedAt: new Date(Number(v.create_time) * 1000).toISOString(),
    durationSec: toInt(v.duration),
    thumbnail: v.cover_image_url ?? null,
  });

  async function query(t: StoredToken, ids: string[]): Promise<Json[]> {
    const out = await api(t, "/video/query/", TIKTOK.videoFields, { filters: { video_ids: ids } });
    return out?.data?.videos ?? [];
  }

  /** Link pendek vm./vt.tiktok.com → URL video (hanya host TikTok, tanpa mengikuti redirect ke host lain). */
  async function resolveShort(url: string): Promise<string> {
    let u: URL;
    try {
      u = new URL(url);
    } catch {
      throw new AdapterError("bad_url");
    }
    if (!/^(vm|vt)\.tiktok\.com$/.test(u.hostname) || u.protocol !== "https:") throw new AdapterError("bad_url");
    try {
      const res = await http.fetch(u.toString(), { redirect: "manual", signal: AbortSignal.timeout(http.timeoutMs) });
      await res.body?.cancel();
      return res.headers.get("location") ?? "";
    } catch {
      throw new Retryable("short link tidak bisa dibuka");
    }
  }

  return {
    platform: "tiktok",
    pkce: "none", // Login Kit web: PKCE hanya untuk desktop/mobile
    maxBatch: TIKTOK.queryMax,

    authorizeUrl(redirectUri, state, codeChallenge) {
      return qs(TIKTOK.authorize, {
        client_key: cfg.clientKey,
        scope: TIKTOK.scopes.join(","),
        response_type: "code",
        redirect_uri: redirectUri,
        state,
        code_challenge: codeChallenge,
        code_challenge_method: codeChallenge ? "S256" : undefined,
      });
    },

    async exchangeCode(code, redirectUri, codeVerifier) {
      const t = await token({ code, grant_type: "authorization_code", redirect_uri: redirectUri, code_verifier: codeVerifier })
        .catch(oauthFailed);
      requireScopes(t.scope, [...TIKTOK.scopes]);
      return t;
    },

    async profile(t): Promise<Profile> {
      const u = (await api(t, "/user/info/", TIKTOK.userFields))?.data?.user ?? {};
      if (!u.open_id) throw new AdapterError("api_error", "profil TikTok kosong");
      return {
        externalId: u.open_id,
        handle: u.username || u.display_name || u.open_id,
        followers: toInt(u.follower_count),
        createdAt: null, // Display API tidak memberi umur akun
        tokenMeta: { open_id: u.open_id, username: u.username ?? "" },
      };
    },

    async listVideos(t, sinceIso) {
      const since = Date.parse(sinceIso) / 1000;
      const out: Video[] = [];
      let cursor: number | undefined;
      for (let page = 0; page < 5; page++) {
        const d = (await api(t, "/video/list/", TIKTOK.videoFields, { max_count: TIKTOK.listMax, cursor }))?.data ?? {};
        const vids: Json[] = d.videos ?? [];
        for (const v of vids) if (Number(v.create_time) >= since) out.push(toVideo(v, t));
        const oldest = Math.min(...vids.map((v) => Number(v.create_time)));
        if (!d.has_more || !vids.length || oldest < since) break;
        cursor = d.cursor;
      }
      return out;
    },

    async getPost(t, postIdOrUrl) {
      let id = videoIdFrom(postIdOrUrl);
      if (!id && /^https:\/\/(vm|vt)\.tiktok\.com\//.test(postIdOrUrl.trim())) id = videoIdFrom(await resolveShort(postIdOrUrl.trim()));
      if (!id) throw new AdapterError("bad_url", "link TikTok tidak dikenali");
      const [v] = await query(t, [id]);
      // video/query hanya mengembalikan video milik user token: kosong = bukan milik akun ini (atau dihapus/private).
      if (!v) throw new AdapterError("not_owner", "video bukan milik akun ini atau tidak publik");
      return toVideo(v, t);
    },

    async fetchMetrics(t, postIds) {
      const results: MetricResult[] = [];
      for (const ids of chunk(postIds, TIKTOK.queryMax)) {
        const byId = new Map((await query(t, ids)).map((v) => [String(v.id), v]));
        for (const id of ids) {
          const v = byId.get(id);
          if (!v) results.push({ postId: id, gone: true, reason: "not_found_or_private" });
          else if (toInt(v.view_count) === null) results.push({ postId: id, retry: true, reason: "view_count_missing" });
          else {
            results.push({
              postId: id,
              views: toInt(v.view_count)!,
              likes: toInt(v.like_count),
              comments: toInt(v.comment_count),
              shares: toInt(v.share_count),
              caption: v.video_description ?? null,
              extra: {},
              raw: v,
            });
          }
        }
      }
      return results;
    },

    async refreshToken(t) {
      if (!t.refresh_token) throw new TokenExpired("refresh_token tidak ada");
      return await token({ grant_type: "refresh_token", refresh_token: t.refresh_token }, t);
    },
  };
}
