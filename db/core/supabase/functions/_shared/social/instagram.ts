// Instagram API with Instagram Login (graph.instagram.com). Hanya akun Professional (Business/Creator);
// akun personal ditolak dengan kode ig_personal. Metrik "views" (plays deprecated 21 Apr 2025).
// Field & metrik dicek ke spec resmi Meta (facebook-business-sdk-codegen: IGMediaForIGOnlyAPI, IGUserForIGOnlyAPI,
// mediainsights_metric_enum_param). API tidak memberi durasi video → durationSec null.
import { defaultHttp, type Fetch, form, graphError, type Http, type Json, oauthFailed, qs, request } from "./net.ts";
import {
  AdapterError,
  expiresAt,
  type MetricResult,
  type PlatformAdapter,
  PostGone,
  type Profile,
  requireScopes,
  type StoredToken,
  toInt,
  TokenExpired,
  type Video,
} from "./types.ts";

export const INSTAGRAM = {
  authorize: "https://www.instagram.com/oauth/authorize",
  token: "https://api.instagram.com/oauth/access_token",
  graph: "https://graph.instagram.com",
  version: "v23.0",
  scopes: ["instagram_business_basic", "instagram_business_manage_insights"],
  mediaFields: "id,caption,media_type,media_product_type,permalink,shortcode,timestamp,thumbnail_url,like_count,comments_count,username",
  reelMetrics: ["views", "reach", "likes", "comments", "shares", "saved", "total_interactions", "ig_reels_avg_watch_time", "reels_skip_rate"],
  baseMetrics: ["views", "reach", "likes", "comments", "shares", "saved"],
  professional: ["BUSINESS", "MEDIA_CREATOR", "CREATOR"],
  pages: 6,
} as const;

/** "2024-05-01T10:00:00+0000" → ISO. */
export const metaTime = (s: string): string => new Date(String(s).replace(/([+-]\d{2})(\d{2})$/, "$1:$2")).toISOString();

/** Insights Graph: {data:[{name, values:[{value}]} | {name, total_value:{value}}]} → {name: value}. */
export function insightValues(body: Json): Record<string, number | null> {
  const out: Record<string, number | null> = {};
  for (const m of body?.data ?? []) out[m.name] = toInt(m.values?.[0]?.value ?? m.total_value?.value);
  return out;
}

export function shortcodeFrom(url: string): string | null {
  const m = /instagram\.com\/(?:[A-Za-z0-9_.]+\/)?(?:reel|reels|p|tv)\/([A-Za-z0-9_-]+)/.exec(url);
  return m ? m[1] : null;
}

export function createInstagram(cfg: { appId: string; appSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const g = (path: string, t: StoredToken, params: Record<string, string | number | undefined> = {}) =>
    request(http, qs(`${INSTAGRAM.graph}/${INSTAGRAM.version}/${path}`, { ...params, access_token: t.access_token }), {}, graphError);

  const toVideo = (m: Json): Video => ({
    postId: String(m.id),
    url: m.permalink,
    caption: m.caption ?? "",
    postedAt: metaTime(m.timestamp),
    durationSec: null,
    thumbnail: m.thumbnail_url ?? null,
  });

  async function* mediaPages(t: StoredToken, params: Record<string, string | number | undefined>): AsyncGenerator<Json[]> {
    let body = await g("me/media", t, { fields: INSTAGRAM.mediaFields, limit: 50, ...params });
    for (let i = 0; i < INSTAGRAM.pages; i++) {
      yield body?.data ?? [];
      const next = body?.paging?.next;
      if (!next || !String(next).startsWith(`${INSTAGRAM.graph}/`)) return;
      body = await request(http, next, {}, graphError);
    }
  }

  async function insights(id: string, t: StoredToken, reel: boolean): Promise<Record<string, number | null>> {
    try {
      return insightValues(await g(`${id}/insights`, t, { metric: (reel ? INSTAGRAM.reelMetrics : INSTAGRAM.baseMetrics).join(",") }));
    } catch (e) {
      // Metrik tidak didukung untuk tipe media ini (code 100) → ulang sekali dengan set dasar.
      if (e instanceof AdapterError && reel) return insightValues(await g(`${id}/insights`, t, { metric: INSTAGRAM.baseMetrics.join(",") }));
      throw e;
    }
  }

  return {
    platform: "instagram",
    pkce: "none",
    maxBatch: 1,

    authorizeUrl(redirectUri, state) {
      return qs(INSTAGRAM.authorize, {
        client_id: cfg.appId,
        redirect_uri: redirectUri,
        response_type: "code",
        scope: INSTAGRAM.scopes.join(","),
        state,
      });
    },

    async exchangeCode(code, redirectUri) {
      try {
        const out = await request(http, INSTAGRAM.token, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: form({ client_id: cfg.appId, client_secret: cfg.appSecret, grant_type: "authorization_code", redirect_uri: redirectUri, code }),
        }, graphError);
        const short = Array.isArray(out?.data) ? out.data[0] : out; // docs: {data:[{access_token,user_id,permissions}]}
        if (!short?.access_token) throw new AdapterError("oauth_failed", "access_token kosong");
        const perms = Array.isArray(short.permissions) ? short.permissions.join(",") : short.permissions;
        requireScopes(perms, [...INSTAGRAM.scopes]);
        const long = await request(
          http,
          qs(`${INSTAGRAM.graph}/access_token`, { grant_type: "ig_exchange_token", client_secret: cfg.appSecret, access_token: short.access_token }),
          {},
          graphError,
        );
        return {
          v: 1,
          access_token: long.access_token,
          expires_at: expiresAt(long.expires_in),
          scope: perms ?? null,
          meta: { ig_user_id: String(short.user_id ?? "") },
        };
      } catch (e) {
        if (e instanceof AdapterError && e.code === "scope_missing") throw e;
        return oauthFailed(e);
      }
    },

    async profile(t): Promise<Profile> {
      const me = await g("me", t, { fields: "id,user_id,username,account_type,followers_count,media_count" });
      const type = String(me.account_type ?? "").toUpperCase();
      if (!(INSTAGRAM.professional as readonly string[]).includes(type)) {
        throw new AdapterError("ig_personal", "akun Instagram harus Professional (Creator/Business)");
      }
      const igId = String(me.user_id ?? me.id);
      return {
        externalId: igId,
        handle: me.username,
        followers: toInt(me.followers_count),
        createdAt: null,
        accountType: type,
        tokenMeta: { ig_user_id: igId, ig_scoped_id: String(me.id ?? ""), username: me.username ?? "" },
      };
    },

    async listVideos(t, sinceIso) {
      const out: Video[] = [];
      const since = Math.floor(Date.parse(sinceIso) / 1000);
      for await (const page of mediaPages(t, { since })) {
        for (const m of page) if (m.media_type === "VIDEO" && Date.parse(metaTime(m.timestamp)) >= since * 1000) out.push(toVideo(m));
      }
      return out;
    },

    async getPost(t, postIdOrUrl) {
      const s = postIdOrUrl.trim();
      let m: Json | undefined;
      if (/^\d{5,30}$/.test(s)) {
        m = await g(s, t, { fields: `${INSTAGRAM.mediaFields},owner` }).catch((e) => {
          if (e instanceof PostGone) throw new AdapterError("not_owner", "post tidak ditemukan di akun ini");
          throw e;
        });
        const owners = [t.meta?.ig_user_id, t.meta?.ig_scoped_id].filter(Boolean);
        const own = (m.owner?.id && owners.includes(String(m.owner.id))) || (m.username && m.username === t.meta?.username);
        if (!own) throw new AdapterError("not_owner", "post bukan milik akun ini");
      } else {
        const code = shortcodeFrom(s);
        if (!code) throw new AdapterError("bad_url", "link Instagram tidak dikenali");
        for await (const page of mediaPages(t, {})) {
          m = page.find((x) => x.shortcode === code || shortcodeFrom(x.permalink ?? "") === code);
          if (m) break;
        }
        if (!m) throw new AdapterError("not_owner", "post tidak ditemukan di akun ini");
      }
      if (m.media_type !== "VIDEO") throw new AdapterError("not_video", "post bukan video/Reels");
      return toVideo(m);
    },

    async fetchMetrics(t, postIds) {
      const results: MetricResult[] = [];
      for (const id of postIds) {
        try {
          const m = await g(id, t, { fields: "id,caption,media_type,media_product_type,like_count,comments_count,timestamp" });
          const ins = await insights(id, t, m.media_product_type === "REELS");
          if (ins.views == null) {
            results.push({ postId: id, retry: true, reason: "views_missing" });
            continue;
          }
          results.push({
            postId: id,
            views: ins.views,
            likes: ins.likes ?? toInt(m.like_count),
            comments: ins.comments ?? toInt(m.comments_count),
            shares: ins.shares ?? null,
            caption: m.caption ?? "",
            extra: {
              reach: ins.reach ?? null,
              saved: ins.saved ?? null,
              total_interactions: ins.total_interactions ?? null,
              avg_watch_time: ins.ig_reels_avg_watch_time ?? null, // milidetik
              skip_rate: ins.reels_skip_rate ?? null,
              media_product_type: m.media_product_type ?? null,
            },
            raw: { media: m, insights: ins },
          });
        } catch (e) {
          if (e instanceof PostGone) results.push({ postId: id, gone: true, reason: e.message });
          else if (e instanceof AdapterError) results.push({ postId: id, failed: true, reason: e.message });
          else throw e; // TokenExpired / Retryable → seluruh batch
        }
      }
      return results;
    },

    async refreshToken(t) {
      const out = await request(
        http,
        qs(`${INSTAGRAM.graph}/refresh_access_token`, { grant_type: "ig_refresh_token", access_token: t.access_token }),
        {},
        (s, b) => graphError(s, b) ?? new TokenExpired(`HTTP ${s}`),
      ).catch((e) => {
        if (e instanceof AdapterError) throw new TokenExpired(e.message);
        throw e;
      });
      return { ...t, access_token: out.access_token, expires_at: expiresAt(out.expires_in) };
    },
  };
}
