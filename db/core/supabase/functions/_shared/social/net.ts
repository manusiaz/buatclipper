// HTTP ke API platform: timeout, parse JSON, dan pemetaan error umum.
// 401 → TokenExpired, 404 → PostGone, 429/5xx/jaringan → Retryable. Error tidak pernah jadi 0 views.
import { AdapterError, PostGone, Retryable, TokenExpired } from "./types.ts";

export type Fetch = typeof fetch;
// deno-lint-ignore no-explicit-any
export type Json = any;
export type ErrorMapper = (status: number, body: Json) => Error | null;

export interface Http {
  fetch: Fetch;
  timeoutMs: number;
}

export const defaultHttp = (f?: Fetch): Http => ({ fetch: f ?? ((...a) => fetch(...a)), timeoutMs: 10_000 });

export function defaultError(status: number, body: Json): Error {
  if (status === 401) return new TokenExpired(`HTTP 401`);
  if (status === 404 || status === 410) return new PostGone(`HTTP ${status}`);
  if (status === 408 || status === 429 || status >= 500) return new Retryable(`HTTP ${status}`);
  const msg = body?.error?.message ?? body?.error_description ?? body?.detail ?? `HTTP ${status}`;
  return new AdapterError("api_error", String(msg));
}

export async function request(http: Http, url: string, init: RequestInit = {}, map?: ErrorMapper): Promise<Json> {
  let res: Response;
  try {
    res = await http.fetch(url, { ...init, signal: AbortSignal.timeout(http.timeoutMs) });
  } catch (e) {
    throw new Retryable(`network: ${e instanceof Error ? e.message : e}`);
  }
  const text = await res.text();
  let body: Json = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  if (!res.ok) throw map?.(res.status, body) ?? defaultError(res.status, body);
  if (body === null) throw new Retryable("respons bukan JSON");
  return body;
}

export const form = (o: Record<string, string | undefined>): URLSearchParams => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(o)) if (v !== undefined) p.set(k, v);
  return p;
};

export const qs = (base: string, o: Record<string, string | number | undefined>): string => {
  const u = new URL(base);
  for (const [k, v] of Object.entries(o)) if (v !== undefined) u.searchParams.set(k, String(v));
  return u.toString();
};

/**
 * Error Graph API Meta (Instagram, Threads, Facebook): {error:{code, error_subcode, is_transient}}.
 * 190 = token tidak valid/kedaluwarsa; 100/33 = objek tidak ada; 4/17/32/613 = rate limit; 1/2 = sementara.
 */
export function graphError(status: number, body: Json): Error | null {
  const e = body?.error;
  const code = Number(e?.code);
  const sub = Number(e?.error_subcode);
  const msg = String(e?.message ?? `HTTP ${status}`);
  if (code === 190 || code === 102) return new TokenExpired(msg);
  if ([1, 2, 4, 17, 32, 341, 613].includes(code) || e?.is_transient === true || status === 429 || status >= 500) {
    return new Retryable(msg);
  }
  if ((code === 100 && sub === 33) || status === 404) return new PostGone(msg);
  if (status === 401) return new TokenExpired(msg);
  if (code === 10 || (code >= 200 && code < 300)) return new AdapterError("permission", msg);
  return new AdapterError("api_error", msg, { code, sub });
}

export function oauthFailed(e: unknown): never {
  if (e instanceof Retryable) throw e;
  throw new AdapterError("oauth_failed", e instanceof Error ? e.message : String(e));
}
