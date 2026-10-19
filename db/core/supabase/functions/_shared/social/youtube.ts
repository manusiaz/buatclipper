// YouTube Data API v3 + YouTube Analytics v2 + Google OAuth (D-11). Field dicek ke discovery document resmi
// (youtube v3: VideoStatistics, VideoStatus, ChannelSnippet, PlaylistItemContentDetails; youtubeAnalytics v2 reports.query).
// videos.list hingga 50 id per panggilan (1 unit kuota). Analytics (negara, sumber traffic, durasi tonton) hanya saat snapshot final.
import { defaultHttp, type Fetch, form, type Http, type Json, oauthFailed, qs, request } from "./net.ts";
import {
  AdapterError,
  chunk,
  expiresAt,
  type MetricResult,
  type PlatformAdapter,
  PostGone,
  type Profile,
  requireScopes,
  Retryable,
  type StoredToken,
  toInt,
  TokenExpired,
  type Video,
} from "./types.ts";

export const YOUTUBE = {
  authorize: "https://accounts.google.com/o/oauth2/v2/auth",
  token: "https://oauth2.googleapis.com/token",
  api: "https://youtube.googleapis.com/youtube/v3",
  analytics: "https://youtubeanalytics.googleapis.com/v2/reports",
  scopes: ["https://www.googleapis.com/auth/youtube.readonly", "https://www.googleapis.com/auth/yt-analytics.readonly"],
  idsPerCall: 50,
} as const;

function googleError(status: number, body: Json): Error {
  const reason = String(body?.error?.errors?.[0]?.reason ?? (typeof body?.error === "string" ? body.error : ""));
  const msg = String(body?.error?.message ?? body?.error_description ?? `HTTP ${status}`);
  if (status === 401 || reason === "invalid_grant" || reason === "authError") return new TokenExpired(msg);
  if (status === 429 || status >= 500 || /rateLimit|quotaExceeded|backendError/i.test(reason)) {
    return new Retryable(msg);
  }
  if (status === 404 || reason === "videoNotFound") return new PostGone(msg);
  if (status === 403) return new AdapterError("permission", msg, { reason });
  return new AdapterError("api_error", msg, { reason });
}

/** ISO 8601 durasi (PT1H2M3S / P1DT…) → detik. */
export function isoDuration(s: string | undefined): number | null {
  const m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(s ?? "");
  if (!m) return null;
  const [, d, h, mi, se] = m.map((x) => Number(x ?? 0));
  return d * 86400 + h * 3600 + mi * 60 + se;
}

export function videoIdFrom(input: string): string | null {
  const s = input.trim();
  if (/^[A-Za-z0-9_-]{11}$/.test(s)) return s;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return null;
  }
  const host = u.hostname.replace(/^(www|m|music)\./, "");
  let id: string | null = null;
  if (host === "youtu.be") id = u.pathname.slice(1).split("/")[0];
  else if (host === "youtube.com") {
    id = u.searchParams.get("v") ?? /^\/(?:shorts|live|embed)\/([^/?#]+)/.exec(u.pathname)?.[1] ?? null;
  }
  return id && /^[A-Za-z0-9_-]{11}$/.test(id) ? id : null;
}

/** Laporan Analytics {columnHeaders:[{name}], rows:[[…]]} → array objek. */
export function reportRows(body: Json): Record<string, string | number>[] {
  const cols: string[] = (body?.columnHeaders ?? []).map((c: Json) => c.name);
  return (body?.rows ?? []).map((r: unknown[]) => Object.fromEntries(cols.map((c, i) => [c, r[i] as string | number])));
}

export function createYouTube(cfg: { clientId: string; clientSecret: string; fetch?: Fetch }): PlatformAdapter {
  const http: Http = defaultHttp(cfg.fetch);
  const get = (url: string, t: StoredToken) =>
    request(http, url, { headers: { authorization: `Bearer ${t.access_token}` } }, googleError);

  async function tokenCall(params: Record<string, string | undefined>, prev?: StoredToken): Promise<StoredToken> {
    const out = await request(http, YOUTUBE.token, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form({ client_id: cfg.clientId, client_secret: cfg.clientSecret, ...params }),
    }, googleError);
    return {
      v: 1,
      access_token: out.access_token,
      refresh_token: out.refresh_token ?? prev?.refresh_token ?? null, // Google tidak selalu mengirim refresh_token baru
      expires_at: expiresAt(out.expires_in),
      scope: out.scope ?? prev?.scope ?? null,
      meta: { ...prev?.meta },
    };
  }

  const toVideo = (v: Json): Video => ({
    postId: v.id,
    url: `https://www.youtube.com/watch?v=${v.id}`,
    caption: [v.snippet?.title, v.snippet?.description].filter(Boolean).join("\n"),
    postedAt: new Date(v.snippet?.publishedAt).toISOString(),
    durationSec: isoDuration(v.contentDetails?.duration),
    thumbnail: v.snippet?.thumbnails?.medium?.url ?? v.snippet?.thumbnails?.default?.url ?? null,
  });

  async function videos(t: StoredToken, ids: string[], part: string): Promise<Json[]> {
    const out: Json[] = [];
    for (const c of chunk(ids, YOUTUBE.idsPerCall)) {
      out.push(...((await get(qs(`${YOUTUBE.api}/videos`, { part, id: c.join(",") }), t))?.items ?? []));
    }
    return out;
  }

  async function analytics(t: StoredToken, id: string, postedAt: string | undefined): Promise<Record<string, unknown>> {
    const base = {
      ids: "channel==MINE",
      startDate: (postedAt ?? "2005-04-23").slice(0, 10),
      endDate: new Date().toISOString().slice(0, 10),
      filters: `video==${id}`,
    };
    const [basic, countries, traffic] = await Promise.all([
      get(qs(YOUTUBE.analytics, { ...base, metrics: "views,averageViewDuration,averageViewPercentage,shares" }), t),
      get(
        qs(YOUTUBE.analytics, { ...base, metrics: "views", dimensions: "country", sort: "-views", maxResults: 10 }),
        t,
      ),
      get(qs(YOUTUBE.analytics, { ...base, metrics: "views", dimensions: "insightTrafficSourceType" }), t),
    ]);
    const b = reportRows(basic)[0] ?? {};
    const toMap = (rows: Record<string, string | number>[], k: string) =>
      Object.fromEntries(rows.map((r) => [r[k], toInt(r.views)]));
    return {
      shares: toInt(b.shares),
      avg_watch_time: toInt(b.averageViewDuration), // detik
      avg_view_percentage: typeof b.averageViewPercentage === "number" ? b.averageViewPercentage : null,
      countries: toMap(reportRows(countries), "country"),
      traffic_sources: toMap(reportRows(traffic), "insightTrafficSourceType"),
    };
  }

  async function profile(t: StoredToken): Promise<Profile> {
    const ch =
      (await get(qs(`${YOUTUBE.api}/channels`, { part: "snippet,statistics,contentDetails", mine: "true" }), t))?.items
        ?.[0];
    if (!ch) throw new AdapterError("no_channel", "akun Google ini belum punya channel YouTube");
    return {
      externalId: ch.id,
      handle: String(ch.snippet?.customUrl ?? ch.snippet?.title ?? ch.id).replace(/^@/, ""),
      followers: ch.statistics?.hiddenSubscriberCount ? null : toInt(ch.statistics?.subscriberCount),
      createdAt: ch.snippet?.publishedAt ?? null,
      tokenMeta: { channel_id: ch.id, uploads: ch.contentDetails?.relatedPlaylists?.uploads ?? "" },
    };
  }

  return {
    platform: "youtube",
    pkce: "optional",
    maxBatch: YOUTUBE.idsPerCall,

    authorizeUrl(redirectUri, state, codeChallenge) {
      return qs(YOUTUBE.authorize, {
        client_id: cfg.clientId,
        redirect_uri: redirectUri,
        response_type: "code",
        scope: YOUTUBE.scopes.join(" "),
        access_type: "offline",
        prompt: "consent", // supaya refresh_token selalu dikirim
        include_granted_scopes: "true",
        state,
        code_challenge: codeChallenge,
        code_challenge_method: codeChallenge ? "S256" : undefined,
      });
    },

    async exchangeCode(code, redirectUri, codeVerifier) {
      const t = await tokenCall({
        code,
        grant_type: "authorization_code",
        redirect_uri: redirectUri,
        code_verifier: codeVerifier,
      })
        .catch(oauthFailed);
      requireScopes(t.scope, [YOUTUBE.scopes[0]]); // analytics opsional; tanpa itu FR-09/FR-11 tidak jalan untuk akun ini
      if (!t.refresh_token) throw new AdapterError("oauth_failed", "Google tidak mengirim refresh_token");
      return t;
    },

    profile,

    async listVideos(t, sinceIso) {
      const since = Date.parse(sinceIso);
      let playlist = t.meta?.uploads;
      if (!playlist) playlist = (await profile(t)).tokenMeta!.uploads;
      const ids: string[] = [];
      let pageToken: string | undefined;
      for (let page = 0; page < 2; page++) {
        const out = await get(
          qs(`${YOUTUBE.api}/playlistItems`, {
            part: "contentDetails",
            playlistId: playlist,
            maxResults: 50,
            pageToken,
          }),
          t,
        );
        let older = false;
        for (const it of out?.items ?? []) {
          const at = Date.parse(it.contentDetails?.videoPublishedAt ?? "");
          if (at >= since) ids.push(it.contentDetails.videoId);
          else older = true;
        }
        pageToken = out?.nextPageToken;
        if (older || !pageToken) break;
      }
      if (!ids.length) return [];
      return (await videos(t, ids, "snippet,contentDetails,status"))
        .filter((v) => v.status?.privacyStatus !== "private")
        .map(toVideo);
    },

    async getPost(t, postIdOrUrl) {
      const id = videoIdFrom(postIdOrUrl);
      if (!id) throw new AdapterError("bad_url", "link YouTube tidak dikenali");
      const [v] = await videos(t, [id], "snippet,contentDetails,status");
      if (!v || v.snippet?.channelId !== t.meta?.channel_id) {
        throw new AdapterError("not_owner", "video bukan milik channel ini");
      }
      if (v.status?.privacyStatus === "private") throw new AdapterError("not_public", "video masih private");
      return toVideo(v);
    },

    async fetchMetrics(t, postIds, opts = {}) {
      const byId = new Map((await videos(t, postIds, "snippet,statistics,status")).map((v) => [v.id as string, v]));
      const results: MetricResult[] = [];
      for (const id of postIds) {
        const v = byId.get(id);
        if (!v) {
          results.push({ postId: id, gone: true, reason: "not_found" });
          continue;
        }
        if (v.status?.privacyStatus === "private") {
          results.push({ postId: id, gone: true, reason: "private" });
          continue;
        }
        const views = toInt(v.statistics?.viewCount);
        if (views === null) {
          results.push({ postId: id, retry: true, reason: "view_count_missing" });
          continue;
        }
        let extra: Record<string, unknown> = {};
        if (opts.final) {
          try {
            extra = await analytics(t, id, opts.postedAt?.[id] ?? v.snippet?.publishedAt);
          } catch (e) {
            if (e instanceof TokenExpired) throw e;
            extra = { analytics_error: e instanceof Error ? e.message : String(e) }; // data tambahan, tidak menggagalkan snapshot
          }
        }
        const { shares = null, ...rest } = extra as { shares?: number | null };
        results.push({
          postId: id,
          views,
          likes: toInt(v.statistics?.likeCount),
          comments: toInt(v.statistics?.commentCount),
          shares,
          caption: [v.snippet?.title, v.snippet?.description].filter(Boolean).join("\n"),
          extra: rest,
          raw: v,
        });
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
