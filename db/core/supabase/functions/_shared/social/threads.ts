// Threads API. Host & alur dicek ke sample resmi Meta (github.com/fbsamples/threads_api): otorisasi di www.threads.com,
// Graph di graph.threads.com, token jangka panjang lewat th_exchange_token; insights media = values[0].value,
// insights user (followers_count) = total_value.value.
import { insightValues, metaTime } from "./instagram.ts";
import { defaultHttp, type Fetch, form, graphError, type Http, type Json, oauthFailed, qs, request } from "./net.ts";
import {
  AdapterError,
  expiresAt,
  type MetricResult,
  type PlatformAdapter,
  PostGone,
  type Profile,
  type StoredToken,
  TokenExpired,
  type Video,
} from "./types.ts";

export const THREADS = {
  authorize: "https://www.threads.com/oauth/authorize",
  graph: "https://graph.threads.com",
  version: "v1.0",
  scopes: ["threads_basic", "threads_manage_insights"],
  mediaFields: "id,media_product_type,media_type,permalink,shortcode,text,timestamp,thumbnail_url,username",
  metrics: ["views", "likes", "replies", "reposts", "quotes", "shares"],
  pages: 4,
} as const;

export function threadsShortcode(url: string): string | null {
  const m = /threads\.(?:net|com)\/@[A-Za-z0-9_.]+\/post\/([A-Za-z0-9_-]+)/.exec(url);
  return m ? m[1] : null;
}

export function createThreads(cfg: { appId: string; appSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const g = (path: string, t: StoredToken, params: Record<string, string | number | undefined> = {}) =>
    request(http, qs(`${THREADS.graph}/${THREADS.version}/${path}`, { ...params, access_token: t.access_token }), {}, graphError);

  const toVideo = (m: Json): Video => ({
    postId: String(m.id),
    url: m.permalink,
    caption: m.text ?? "",
    postedAt: metaTime(m.timestamp),
    durationSec: null, // Threads API tidak memberi durasi video
    thumbnail: m.thumbnail_url ?? null,
  });

  async function* pages(t: StoredToken, params: Record<string, string | number | undefined>): AsyncGenerator<Json[]> {
    let body = await g("me/threads", t, { fields: THREADS.mediaFields, limit: 50, ...params });
    for (let i = 0; i < THREADS.pages; i++) {
      yield body?.data ?? [];
      const next = body?.paging?.next;
      if (!next || !String(next).startsWith(`${THREADS.graph}/`)) return;
      body = await request(http, next, {}, graphError);
    }
  }

  return {
    platform: "threads",
    pkce: "none",
    maxBatch: 1,

    authorizeUrl(redirectUri, state) {
      return qs(THREADS.authorize, {
        client_id: cfg.appId,
        redirect_uri: redirectUri,
        scope: THREADS.scopes.join(","),
        response_type: "code",
        state,
      });
    },

    async exchangeCode(code, redirectUri) {
      try {
        const short = await request(http, `${THREADS.graph}/oauth/access_token`, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: form({ client_id: cfg.appId, client_secret: cfg.appSecret, grant_type: "authorization_code", redirect_uri: redirectUri, code }),
        }, graphError);
        const long = await request(
          http,
          qs(`${THREADS.graph}/access_token`, { grant_type: "th_exchange_token", client_secret: cfg.appSecret, access_token: short.access_token }),
          {},
          graphError,
        );
        return {
          v: 1,
          access_token: long.access_token,
          expires_at: expiresAt(long.expires_in),
          scope: null,
          meta: { threads_user_id: String(short.user_id ?? "") },
        };
      } catch (e) {
        return oauthFailed(e);
      }
    },

    async profile(t): Promise<Profile> {
      const me = await g("me", t, { fields: "id,username,name" });
      let followers: number | null = null;
      try {
        const ins = await g("me/threads_insights", t, { metric: "followers_count" });
        followers = insightValues(ins).followers_count ?? null;
      } catch (e) {
        if (e instanceof TokenExpired) throw e; // izin insights belum disetujui → follower tidak diketahui
      }
      return {
        externalId: String(me.id),
        handle: me.username,
        followers,
        createdAt: null,
        tokenMeta: { threads_user_id: String(me.id), username: me.username ?? "" },
      };
    },

    async listVideos(t, sinceIso) {
      const since = Math.floor(Date.parse(sinceIso) / 1000);
      const out: Video[] = [];
      for await (const page of pages(t, { since })) {
        for (const m of page) if (m.media_type === "VIDEO" && Date.parse(metaTime(m.timestamp)) >= since * 1000) out.push(toVideo(m));
      }
      return out;
    },

    async getPost(t, postIdOrUrl) {
      const s = postIdOrUrl.trim();
      let m: Json | undefined;
      if (/^\d{5,30}$/.test(s)) {
        m = await g(s, t, { fields: THREADS.mediaFields }).catch((e) => {
          if (e instanceof PostGone) throw new AdapterError("not_owner", "post tidak ditemukan di akun ini");
          throw e;
        });
        if (!m.username || m.username !== t.meta?.username) throw new AdapterError("not_owner", "post bukan milik akun ini");
      } else {
        const code = threadsShortcode(s);
        if (!code) throw new AdapterError("bad_url", "link Threads tidak dikenali");
        for await (const page of pages(t, {})) {
          m = page.find((x) => x.shortcode === code || threadsShortcode(x.permalink ?? "") === code);
          if (m) break;
        }
        if (!m) throw new AdapterError("not_owner", "post tidak ditemukan di akun ini");
      }
      if (m.media_type !== "VIDEO") throw new AdapterError("not_video", "post bukan video");
      return toVideo(m);
    },

    async fetchMetrics(t, postIds) {
      const results: MetricResult[] = [];
      for (const id of postIds) {
        try {
          const m = await g(id, t, { fields: "id,text,timestamp,media_type" });
          const ins = insightValues(await g(`${id}/insights`, t, { metric: THREADS.metrics.join(",") }));
          if (ins.views == null) {
            results.push({ postId: id, retry: true, reason: "views_missing" });
            continue;
          }
          results.push({
            postId: id,
            views: ins.views,
            likes: ins.likes ?? null,
            comments: ins.replies ?? null,
            shares: ins.shares ?? null,
            caption: m.text ?? "",
            extra: { reposts: ins.reposts ?? null, quotes: ins.quotes ?? null },
            raw: { media: m, insights: ins },
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
      const out = await request(
        http,
        qs(`${THREADS.graph}/refresh_access_token`, { grant_type: "th_refresh_token", access_token: t.access_token }),
        {},
        graphError,
      ).catch((e) => {
        if (e instanceof AdapterError) throw new TokenExpired(e.message);
        throw e;
      });
      return { ...t, access_token: out.access_token, expires_at: expiresAt(out.expires_in) };
    },
  };
}
