// Akses DB core hanya lewat RPC schema api (service role) dan view api (publik / JWT user, RLS berlaku).
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { env, HttpError } from "./http.ts";

export class RpcError extends Error {
  constructor(public fn: string, public code: string, message: string, public details?: string) {
    super(message);
  }
}

/** Satu-satunya cara fungsi menyentuh data: rpc('worker_…', args). Dibuat interface supaya tes bisa memakai RPC palsu. */
export type Rpc = <T = unknown>(fn: string, args?: Record<string, unknown>) => Promise<T>;

function firstKey(jsonEnv: string, prefer: string): string | undefined {
  const raw = Deno.env.get(jsonEnv);
  if (!raw) return undefined;
  try {
    const v = JSON.parse(raw);
    // Kosong = belum diset (compose self-hosted resmi mengisi {"default":""} kalau key baru tidak dipakai).
    const ok = (k: unknown): k is string => typeof k === "string" && k.length > 0;
    if (Array.isArray(v)) return v.find(ok);
    return ok(v?.[prefer]) ? v[prefer] : Object.values(v ?? {}).find(ok);
  } catch {
    return undefined;
  }
}

export function serviceKey(): string {
  const k = firstKey("SUPABASE_SECRET_KEYS", "default") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!k) throw new HttpError(500, "misconfigured", "secret key core tidak ada");
  return k;
}

function publishableKey(): string {
  const k = firstKey("SUPABASE_PUBLISHABLE_KEYS", "default") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!k) throw new HttpError(500, "misconfigured", "publishable key core tidak ada");
  return k;
}

const opts = { auth: { persistSession: false, autoRefreshToken: false }, db: { schema: "api" } } as const;

// deno-lint-ignore no-explicit-any
export type Db = SupabaseClient<any, any, "api", any, any>;

let service: Db | null = null;

export function serviceClient(): Db {
  return service ??= createClient(env("SUPABASE_URL"), serviceKey(), opts);
}

/** Client anon: view publik (mis. api.settings key public.*). */
export function publicClient(): Db {
  return createClient(env("SUPABASE_URL"), publishableKey(), opts);
}

/** Client atas nama user (JWT identity lewat Third-Party Auth): RLS core membatasi baris ke milik user. */
export function userClient(jwt: string): Db {
  return createClient(env("SUPABASE_URL"), publishableKey(), { ...opts, accessToken: () => Promise.resolve(jwt) });
}

export function rpcFrom(client: Db): Rpc {
  return async <T>(fn: string, args: Record<string, unknown> = {}) => {
    const { data, error } = await client.rpc(fn, args);
    if (error) throw new RpcError(fn, error.code ?? "", error.message, error.details ?? undefined);
    return data as T;
  };
}

export function serviceRpc(): Rpc {
  return rpcFrom(serviceClient());
}
