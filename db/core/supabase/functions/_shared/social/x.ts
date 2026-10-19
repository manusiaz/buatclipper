// X API v2, OAuth 2.0 Authorization Code + PKCE (wajib). Endpoint & alur token dicek ke SDK resmi @xdevplatform/xdk
// (x.com/i/oauth2/authorize, api.x.com/2/oauth2/token, Basic auth untuk confidential client; refresh token berotasi).
// Bayar per read (US$0,005/post): worker hanya memanggil di 24 jam, 7 hari, dan lock (§11). Lookup maks 100 id per panggilan.
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

export const X = {
  authorize: "https://x.com/i/oauth2/authorize",
  token: "https://api.x.com/2/oauth2/token",
  api: "https://api.x.com/2",
  scopes: ["tweet.read", "users.read", "offline.access"],
  tweetFields: "created_at,public_metrics,author_id,text,note_tweet,attachments",
  mediaFields: "type,duration_ms,preview_image_url,public_metrics",
  lookupMax: 100,
} as const;

function xError(status: number, body: Json): Error {
  const msg = String(body?.detail ?? body?.title ?? body?.error_description ?? body?.error ?? `HTTP ${status}`);
  if (status === 401 || body?.error === "invalid_grant" || (body?.error === "invalid_request" && /token/i.test(msg))) {
    return new TokenExpired(msg);
  }
  if (status === 429 || status >= 500) return new Retryable(msg);
  return new AdapterError("api_error", msg, { status });
}

export function tweetIdFrom(input: string): string | null {
  const s = input.trim();
  if (/^\d{5,25}$/.test(s)) return s;
  const m = /^https:\/\/(?:www\.|mobile\.)?(?:x|twitter)\.com\/[A-Za-z0-9_]+\/status\/(\d{5,25})/.exec(s);
  return m ? m[1] : null;
}

export function createX(cfg: { clientId: string; clientSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const basic = `Basic ${btoa(`${cfg.clientId}:${cfg.clientSecret}`)}`;
  const get = (url: string, t: StoredToken) => request(http, url, { headers: { authorization: `Bearer ${t.access_token}` } }, xError);

  async function tokenCall(params: Record<string, string | undefined>, prev?: StoredToken): Promise<StoredToken> {
    const out = await request(http, X.token, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", authorization: basic },
      body: form({ client_id: cfg.clientId, ...params }),
    }, xError);
    return {
      v: 1,
      access_token: out.access_token,
      refresh_token: out.refresh_token ?? prev?.refresh_token ?? null, // berotasi: simpan yang baru
      expires_at: expiresAt(out.expires_in),
      scope: out.scope ?? prev?.scope ?? null,
      meta: { ...prev?.meta },
    };
  }

  function videoOf(tw: Json, media: Map<string, Json>): Json | undefined {
    return (tw.attachments?.media_keys ?? []).map((k: string) => media.get(k)).find((m: Json) => m?.type === "video");
  }

  const toVideo = (tw: Json, media: Map<string, Json>, username: string): Video => {
    const vid = videoOf(tw, media);
    return {
      postId: String(tw.id),
      url: `https://x.com/${username || "i"}/status/${tw.id}`,
      caption: tw.note_tweet?.text ?? tw.text ?? "",
      postedAt: new Date(tw.created_at).toISOString(),
      durationSec: vid?.duration_ms != null ? Math.round(vid.duration_ms / 1000) : null,
      thumbnail: vid?.preview_image_url ?? null,
    };
  };

  const mediaMap = (body: Json) => new Map<string, Json>((body?.includes?.media ?? []).map((m: Json) => [m.media_key, m]));

  async function lookup(t: StoredToken, ids: string[]): Promise<Json> {
    return await get(qs(`${X.api}/tweets`, {
      ids: ids.join(","),
      "tweet.fields": X.tweetFields,
      expansions: "attachments.media_keys",
      "media.fields": X.mediaFields,
    }), t);
  }

  return {
    platform: "x",
    pkce: "required",
    maxBatch: X.lookupMax,

    authorizeUrl(redirectUri, state, codeChallenge) {
      if (!codeChallenge) throw new AdapterError("pkce_required");
      return qs(X.authorize, {
        response_type: "code",
        client_id: cfg.clientId,
        redirect_uri: redirectUri,
        scope: X.scopes.join(" "),
        state,
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
      });
    },

    async exchangeCode(code, redirectUri, codeVerifier) {
      if (!codeVerifier) throw new AdapterError("oauth_failed", "code_verifier wajib untuk X");
      const t = await tokenCall({ code, grant_type: "authorization_code", redirect_uri: redirectUri, code_verifier: codeVerifier })
        .catch(oauthFailed);
      requireScopes(t.scope, [...X.scopes]);
      return t;
    },

    async profile(t): Promise<Profile> {
      const u = (await get(qs(`${X.api}/users/me`, { "user.fields": "created_at,public_metrics,username" }), t))?.data;
      if (!u?.id) throw new AdapterError("api_error", "profil X kosong");
      return {
        externalId: String(u.id),
        handle: u.username,
        followers: toInt(u.public_metrics?.followers_count),
        createdAt: u.created_at ?? null,
        tokenMeta: { user_id: String(u.id), username: u.username ?? "" },
      };
    },

    async listVideos(t, sinceIso) {
      const uid = t.meta?.user_id;
      if (!uid) throw new TokenExpired("user_id tidak ada di token");
      const body = await get(qs(`${X.api}/users/${uid}/tweets`, {
        start_time: new Date(sinceIso).toISOString().replace(/\.\d{3}Z$/, "Z"), // YYYY-MM-DDTHH:mm:ssZ
        max_results: 100,
        exclude: "retweets,replies",
        "tweet.fields": X.tweetFields,
        expansions: "attachments.media_keys",
        "media.fields": X.mediaFields,
      }), t);
      const media = mediaMap(body);
      return (body?.data ?? []).filter((tw: Json) => videoOf(tw, media)).map((tw: Json) => toVideo(tw, media, t.meta?.username ?? ""));
    },

    async getPost(t, postIdOrUrl) {
      const id = tweetIdFrom(postIdOrUrl);
      if (!id) throw new AdapterError("bad_url", "link X tidak dikenali");
      const body = await lookup(t, [id]);
      const tw = body?.data?.[0];
      if (!tw || String(tw.author_id) !== t.meta?.user_id) throw new AdapterError("not_owner", "post bukan milik akun ini");
      const media = mediaMap(body);
      if (!videoOf(tw, media)) throw new AdapterError("not_video", "post tidak berisi video");
      return toVideo(tw, media, t.meta?.username ?? "");
    },

    async fetchMetrics(t, postIds) {
      const results: MetricResult[] = [];
      for (const ids of chunk(postIds, X.lookupMax)) {
        const body = await lookup(t, ids);
        const media = mediaMap(body);
        const byId = new Map<string, Json>((body?.data ?? []).map((tw: Json) => [String(tw.id), tw]));
        const errs = new Map<string, string>(
          (body?.errors ?? []).map((e: Json) => [String(e.resource_id ?? e.value ?? ""), String(e.title ?? e.detail ?? "error")]),
        );
        for (const id of ids) {
          const tw = byId.get(id);
          if (!tw) {
            results.push({ postId: id, gone: true, reason: errs.get(id) ?? "not_found" });
            continue;
          }
          const pm = tw.public_metrics ?? {};
          const views = toInt(pm.impression_count);
          if (views === null) {
            results.push({ postId: id, retry: true, reason: "impression_count_missing" });
            continue;
          }
          results.push({
            postId: id,
            views,
            likes: toInt(pm.like_count),
            comments: toInt(pm.reply_count),
            shares: toInt(pm.retweet_count),
            caption: tw.note_tweet?.text ?? tw.text ?? "",
            extra: {
              quotes: toInt(pm.quote_count),
              bookmarks: toInt(pm.bookmark_count),
              video_views: toInt(videoOf(tw, media)?.public_metrics?.view_count),
            },
            raw: { tweet: tw, media: videoOf(tw, media) ?? null },
          });
        }
      }
      return results;
    },

    async refreshToken(t) {
      if (!t.refresh_token) throw new TokenExpired("refresh_token tidak ada");
      return await tokenCall({ grant_type: "refresh_token", refresh_token: t.refresh_token }, t).catch((e) => {
        if (e instanceof AdapterError) throw new TokenExpired(e.message);
        throw e;
      });
    },
  };
}
