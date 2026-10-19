// Registri adapter + feature flag platform (public.flags.platforms, bisa dimatikan tanpa deploy, §15.9) + PKCE.
import { publicClient, type Rpc } from "../db.ts";
import { base64url, env, randomToken } from "../http.ts";
import { createFacebook } from "./facebook.ts";
import { createInstagram } from "./instagram.ts";
import type { Fetch } from "./net.ts";
import { createThreads } from "./threads.ts";
import { createTikTok } from "./tiktok.ts";
import { needsRefresh, type Platform, type PlatformAdapter, type StoredToken } from "./types.ts";
import { createX } from "./x.ts";
import { createYouTube } from "./youtube.ts";

export * from "./types.ts";

/** Env client id/secret per platform (secret hanya di Edge Functions core, §15.7). */
export const PLATFORM_ENV: Record<Platform, [string, string]> = {
  tiktok: ["TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET"],
  instagram: ["META_APP_ID", "META_APP_SECRET"],
  youtube: ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"],
  threads: ["THREADS_APP_ID", "THREADS_APP_SECRET"],
  facebook: ["FACEBOOK_APP_ID", "FACEBOOK_APP_SECRET"],
  x: ["X_CLIENT_ID", "X_CLIENT_SECRET"],
};

export function adapterFor(p: Platform, fetch?: Fetch): PlatformAdapter {
  const [idName, secretName] = PLATFORM_ENV[p];
  const id = env(idName), secret = env(secretName);
  switch (p) {
    case "tiktok":
      return createTikTok({ clientKey: id, clientSecret: secret, fetch });
    case "instagram":
      return createInstagram({ appId: id, appSecret: secret, fetch });
    case "youtube":
      return createYouTube({ clientId: id, clientSecret: secret, fetch });
    case "threads":
      return createThreads({ appId: id, appSecret: secret, fetch });
    case "facebook":
      return createFacebook({ appId: id, appSecret: secret, fetch });
    case "x":
      return createX({ clientId: id, clientSecret: secret, fetch });
  }
}

export type FlagLoader = () => Promise<Record<string, boolean>>;

/** api.settings key public.flags.platforms (terbaca anon lewat policy settings_public_read). */
export const loadPlatformFlags: FlagLoader = async () => {
  const { data, error } = await publicClient().from("settings").select("value").eq("key", "public.flags.platforms").maybeSingle();
  if (error) throw new Error(`settings: ${error.message}`);
  const v = data?.value;
  return v && typeof v === "object" ? v as Record<string, boolean> : {};
};

let flagCache: { at: number; flags: Record<string, boolean> } | null = null;

/** Cache 60 detik per isolate. Platform yang tidak ada di flag = mati (fail closed). */
export async function platformFlags(load: FlagLoader = loadPlatformFlags, now = Date.now()): Promise<Record<string, boolean>> {
  if (flagCache && now - flagCache.at < 60_000) return flagCache.flags;
  const flags = await load();
  flagCache = { at: now, flags };
  return flags;
}

export function resetFlagCache(): void {
  flagCache = null;
}

export async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const verifier = randomToken(48);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

/** Token hampir kedaluwarsa (YouTube 1 jam, X 2 jam, TikTok 24 jam) → refresh dulu lalu simpan ke Vault. */
export async function ensureFresh(
  adapter: PlatformAdapter,
  token: StoredToken,
  accountId: string,
  rpc: Rpc,
  now = Date.now(),
): Promise<StoredToken> {
  if (!needsRefresh(token, 120_000, now)) return token;
  const fresh = await adapter.refreshToken(token);
  await rpc("store_social_token", { p_account_id: accountId, p_token: JSON.stringify(fresh) });
  return fresh;
}
