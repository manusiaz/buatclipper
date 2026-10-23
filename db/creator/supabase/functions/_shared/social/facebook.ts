// Facebook Pages (Graph API). Hanya Page, bukan profil pribadi. Token yang disimpan = Page access token dari
// user token jangka panjang (tidak kedaluwarsa, tapi bisa dicabut → error 190). Field dicek ke spec resmi Meta
// (facebook-business-sdk-codegen: Page.video_reels/videos, AdVideo.views/length/post_id/from, PagePost.shares).
import { metaTime } from "./instagram.ts";
import { defaultHttp, type Fetch, graphError, type Http, type Json, oauthFailed, qs, request } from "./net.ts";
import {
  AdapterError,
  type MetricResult,
  type PlatformAdapter,
  PostGone,
  type Profile,
  type StoredToken,
  toInt,
  TokenExpired,
  type Video,
} from "./types.ts";

const FB_VERSION = "v23.0";

export const FACEBOOK = {
  version: FB_VERSION,
  dialog: `https://www.facebook.com/${FB_VERSION}/dialog/oauth`,
  graph: `https://graph.facebook.com/${FB_VERSION}`,
  scopes: ["pages_show_list", "pages_read_engagement", "read_insights"],
  videoFields: "id,description,created_time,length,permalink_url,picture,from,post_id",
  metricFields:
    "id,description,created_time,views,post_id,from,likes.summary(true).limit(0),comments.summary(true).limit(0)",
} as const;

export function fbVideoIdFrom(input: string): string | null {
  const s = input.trim();
  if (/^\d{5,30}$/.test(s)) return s;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  if (!/(^|\.)facebook\.com$/.test(u.hostname)) return null;
  return u.searchParams.get("v") ?? /\/(?:reel|videos)\/(?:[^/]+\/)?(\d{5,30})/.exec(u.pathname)?.[1] ?? null;
}

const absolute = (p: string | undefined, id: string) =>
  !p ? `https://www.facebook.com/reel/${id}` : p.startsWith("/") ? `https://www.facebook.com${p}` : p;

export function createFacebook(cfg: { appId: string; appSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const g = (path: string, token: string, params: Record<string, string | number | undefined> = {}) =>
    request(http, qs(`${FACEBOOK.graph}/${path}`, { ...params, access_token: token }), {}, graphError);
  const pageId = (t: StoredToken) => {
    if (!t.meta?.page_id) throw new TokenExpired("page_id tidak ada di token");
    return t.meta.page_id;
  };

  const toVideo = (v: Json): Video => ({
    postId: String(v.id),
    url: absolute(v.permalink_url, v.id),
    caption: v.description ?? "",
    postedAt: metaTime(v.created_time),
    durationSec: typeof v.length === "number" ? Math.round(v.length) : null,
    thumbnail: v.picture ?? null,
  });

  return {
    platform: "facebook",
    pkce: "none",
    maxBatch: 1,

    authorizeUrl(redirectUri, state) {
      return qs(FACEBOOK.dialog, {
        client_id: cfg.appId,
        redirect_uri: redirectUri,
        state,
        response_type: "code",
        scope: FACEBOOK.scopes.join(","),
      });
    },

    async exchangeCode(code, redirectUri, _verifier, opts = {}) {
      let pages: Json[];
      try {
        const user = await request(
          http,
          qs(`${FACEBOOK.graph}/oauth/access_token`, {
            client_id: cfg.appId,
            client_secret: cfg.appSecret,
            redirect_uri: redirectUri,
            code,
          }),
          {},
          graphError,
        );
        const long = await request(
          http,
          qs(`${FACEBOOK.graph}/oauth/access_token`, {
            grant_type: "fb_exchange_token",
            client_id: cfg.appId,
            client_secret: cfg.appSecret,
            fb_exchange_token: user.access_token,
          }),
          {},
          graphError,
        );
        pages =
          (await g("me/accounts", long.access_token, { fields: "id,name,username,access_token", limit: 100 }))?.data ??
            [];
      } catch (e) {
        return oauthFailed(e);
      }
      if (!pages.length) throw new AdapterError("no_page", "akun Facebook ini tidak mengelola Page");
      const page = opts.pageId ? pages.find((p) => p.id === opts.pageId) : pages.length === 1 ? pages[0] : undefined;
      if (!page) {
        throw new AdapterError("page_ambiguous", "pilih satu Page", pages.map((p) => ({ id: p.id, name: p.name })));
      }
      // Page token dari user token jangka panjang tidak punya masa berlaku.
      return {
        v: 1,
        access_token: page.access_token,
        expires_at: null,
        scope: null,
        meta: { page_id: String(page.id) },
      };
    },

    async profile(t): Promise<Profile> {
      const p = await g(pageId(t), t.access_token, { fields: "id,name,username,followers_count,fan_count" });
      return {
        externalId: String(p.id),
        handle: p.username ?? p.name,
        followers: toInt(p.followers_count) ?? toInt(p.fan_count),
        createdAt: null,
        accountType: "PAGE",
        tokenMeta: { page_id: String(p.id) },
      };
    },

    async listVideos(t, sinceIso) {
      const since = Date.parse(sinceIso);
      const id = pageId(t);
      const [reels, vids] = await Promise.all([
        g(`${id}/video_reels`, t.access_token, {
          fields: FACEBOOK.videoFields,
          since: Math.floor(since / 1000),
          limit: 50,
        }),
        g(`${id}/videos`, t.access_token, { fields: FACEBOOK.videoFields, type: "uploaded", limit: 50 }),
      ]);
      const seen = new Map<string, Json>();
      for (const v of [...(reels?.data ?? []), ...(vids?.data ?? [])]) seen.set(String(v.id), v);
      return [...seen.values()].filter((v) => Date.parse(metaTime(v.created_time)) >= since).map(toVideo);
    },

    async getPost(t, postIdOrUrl) {
      const id = fbVideoIdFrom(postIdOrUrl);
      if (!id) throw new AdapterError("bad_url", "link video/Reels Facebook tidak dikenali");
      const v = await g(id, t.access_token, { fields: FACEBOOK.videoFields }).catch((e) => {
        if (e instanceof PostGone) throw new AdapterError("not_owner", "video tidak ditemukan di Page ini");
        throw e;
      });
      if (String(v.from?.id ?? "") !== pageId(t)) throw new AdapterError("not_owner", "video bukan milik Page ini");
      return toVideo(v);
    },

    async fetchMetrics(t, postIds) {
      const results: MetricResult[] = [];
      for (const id of postIds) {
        try {
          const v = await g(id, t.access_token, { fields: FACEBOOK.metricFields });
          const views = toInt(v.views);
          if (views === null) {
            results.push({ postId: id, retry: true, reason: "views_missing" });
            continue;
          }
          let shares: number | null = null;
          if (v.post_id) {
            try {
              shares = toInt((await g(String(v.post_id), t.access_token, { fields: "shares" }))?.shares?.count) ?? 0;
            } catch (e) {
              if (e instanceof TokenExpired) throw e;
            }
          }
          results.push({
            postId: id,
            views,
            likes: toInt(v.likes?.summary?.total_count),
            comments: toInt(v.comments?.summary?.total_count),
            shares,
            caption: v.description ?? "",
            extra: {},
            raw: v,
          });
        } catch (e) {
          if (e instanceof PostGone) results.push({ postId: id, gone: true, reason: e.message });
          else if (e instanceof AdapterError) results.push({ postId: id, failed: true, reason: e.message });
          else throw e;
        }
      }
      return results;
    },

    async refreshToken(t) {
      // Page token tidak kedaluwarsa; cukup pastikan belum dicabut (190 → TokenExpired).
      await g(pageId(t), t.access_token, { fields: "id" });
      return t;
    },
  };
}
