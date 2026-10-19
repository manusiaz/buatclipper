// Supabase access for identity Edge Functions. The service client uses the project's secret key (role service_role)
// and the api schema only (the Data API exposes nothing else). Thin interfaces (Rpc, Storage, AuthAdmin) keep the
// handlers testable with fakes.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { env, envJsonValues, envOpt, HttpError } from "./http.ts";

export class DbError extends HttpError {
  constructor(public pgCode: string, public dbMessage: string) {
    super(500, "db_error", "kesalahan database");
    this.name = "DbError";
  }
}

// deno-lint-ignore no-explicit-any
export type Client = SupabaseClient<any, any, any, any, any>;

export interface Rpc {
  invoke<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T>;
}

function firstKey(single: string, jsonName: string): string | undefined {
  const keys = envJsonValues(jsonName);
  return envOpt(single) ?? keys[0];
}

export function serviceKey(): string {
  const k = firstKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS");
  if (!k) throw new HttpError(500, "config_missing", "server belum dikonfigurasi");
  return k;
}

function publishableKey(): string {
  const k = firstKey("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS");
  if (!k) throw new HttpError(500, "config_missing", "server belum dikonfigurasi");
  return k;
}

let service: Client | undefined;
export function serviceClient(): Client {
  service ??= createClient(env("SUPABASE_URL"), serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    db: { schema: "api" },
  });
  return service;
}

export function supabaseRpc(client: Client): Rpc {
  return {
    async invoke<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      const { data, error } = await client.rpc(fn, args);
      if (error) throw new DbError(error.code ?? "", error.message ?? "");
      return data as T;
    },
  };
}

/** RPC as the end user (their JWT → auth.uid()), e.g. api.record_consent. */
export function userRpc(jwt: string): Rpc {
  const client = createClient(env("SUPABASE_URL"), publishableKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    db: { schema: "api" },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  return supabaseRpc(client);
}

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/** Calls a set-returning svc_* function in chunks of ids (§15.9: pii-export splits big batches). */
export async function rpcByIds<T>(rpc: Rpc, fn: string, argName: string, ids: string[], size = 500): Promise<T[]> {
  const unique = [...new Set(ids)];
  const out: T[] = [];
  for (const part of chunk(unique, size)) {
    const rows = await rpc.invoke<T[] | null>(fn, { [argName]: part });
    if (rows) out.push(...rows);
  }
  return out;
}

// ---- storage ----------------------------------------------------------------------------------------------------

export interface Storage {
  upload(bucket: string, path: string, body: Uint8Array, contentType: string, upsert: boolean): Promise<void>;
  signedUrl(bucket: string, path: string, expiresIn: number): Promise<string>;
  exists(bucket: string, path: string): Promise<boolean>;
  listAll(bucket: string, prefix: string): Promise<string[]>;
  remove(bucket: string, paths: string[]): Promise<void>;
}

export function supabaseStorage(client: Client): Storage {
  return {
    async upload(bucket, path, body, contentType, upsert) {
      const { error } = await client.storage.from(bucket).upload(path, body, {
        contentType,
        upsert,
        cacheControl: "0",
      });
      if (error) {
        const status = (error as { statusCode?: string | number }).statusCode;
        if (String(status) === "409") throw new HttpError(409, "file_exists", "berkas sudah ada");
        throw new HttpError(502, "storage_error", "gagal menyimpan berkas");
      }
    },
    async signedUrl(bucket, path, expiresIn) {
      const { data, error } = await client.storage.from(bucket).createSignedUrl(path, expiresIn);
      if (error || !data?.signedUrl) throw new HttpError(502, "storage_error", "gagal membuat link unduh");
      return data.signedUrl;
    },
    async exists(bucket, path) {
      const { data, error } = await client.storage.from(bucket).exists(path);
      if (error && data !== false) throw new HttpError(502, "storage_error", "gagal memeriksa berkas");
      return data === true;
    },
    async listAll(bucket, prefix) {
      const out: string[] = [];
      const walk = async (dir: string, depth: number): Promise<void> => {
        for (let offset = 0;; offset += 100) {
          const { data, error } = await client.storage.from(bucket).list(dir, { limit: 100, offset });
          if (error) throw new HttpError(502, "storage_error", "gagal membaca berkas");
          for (const f of data ?? []) {
            const full = `${dir}/${f.name}`;
            if (f.id === null && depth < 3) await walk(full, depth + 1); // folder placeholder
            else if (f.id !== null) out.push(full);
          }
          if (!data || data.length < 100) break;
        }
      };
      await walk(prefix.replace(/\/+$/, ""), 0);
      return out;
    },
    async remove(bucket, paths) {
      for (let i = 0; i < paths.length; i += 100) {
        const { error } = await client.storage.from(bucket).remove(paths.slice(i, i + 100));
        if (error) throw new HttpError(502, "storage_error", "gagal menghapus berkas");
      }
    },
  };
}

// ---- auth admin ---------------------------------------------------------------------------------------------------

export interface AuthUser {
  id: string;
  email?: string;
  banned_until?: string | null;
}

export interface AuthAdmin {
  getUser(id: string): Promise<AuthUser | null>;
  deleteUser(id: string): Promise<void>;
  setBan(id: string, banDuration: string): Promise<AuthUser>;
  invite(email: string, redirectTo: string, data: Record<string, unknown>): Promise<AuthUser>;
  listFactors(userId: string): Promise<{ id: string }[]>;
  deleteFactor(userId: string, factorId: string): Promise<void>;
}

function authStatus(err: unknown): { status?: number; code?: string } {
  const e = err as { status?: number; code?: string };
  return { status: e?.status, code: e?.code };
}

export function supabaseAuthAdmin(client: Client): AuthAdmin {
  const admin = client.auth.admin;
  return {
    async getUser(id) {
      const { data, error } = await admin.getUserById(id);
      if (error) {
        if (authStatus(error).status === 404 || authStatus(error).code === "user_not_found") return null;
        throw new HttpError(502, "auth_error", "gagal membaca akun");
      }
      const u = data.user;
      return u ? { id: u.id, email: u.email ?? undefined, banned_until: u.banned_until ?? null } : null;
    },
    async deleteUser(id) {
      const { error } = await admin.deleteUser(id, false);
      if (error && authStatus(error).status !== 404 && authStatus(error).code !== "user_not_found") {
        throw new HttpError(502, "auth_error", "gagal menghapus akun");
      }
    },
    async setBan(id, banDuration) {
      const { data, error } = await admin.updateUserById(id, { ban_duration: banDuration });
      if (error) {
        if (authStatus(error).status === 404 || authStatus(error).code === "user_not_found") {
          throw new HttpError(404, "user_not_found", "akun tidak ditemukan");
        }
        throw new HttpError(502, "auth_error", "gagal mengubah status akun");
      }
      return { id: data.user.id, banned_until: data.user.banned_until ?? null };
    },
    async invite(email, redirectTo, data) {
      const res = await admin.inviteUserByEmail(email, { redirectTo, data });
      if (res.error) {
        const { status, code } = authStatus(res.error);
        if (code === "email_exists" || status === 422) {
          throw new HttpError(409, "already_registered", "email sudah terdaftar");
        }
        throw new HttpError(502, "auth_error", "gagal mengirim undangan");
      }
      return { id: res.data.user.id };
    },
    async listFactors(userId) {
      const { data, error } = await admin.mfa.listFactors({ userId });
      if (error) throw new HttpError(502, "auth_error", "gagal membaca faktor MFA");
      return (data?.factors ?? []).map((f) => ({ id: f.id }));
    },
    async deleteFactor(userId, factorId) {
      const { error } = await admin.mfa.deleteFactor({ userId, id: factorId });
      if (error && authStatus(error).status !== 404) {
        throw new HttpError(502, "auth_error", "gagal menghapus faktor MFA");
      }
    },
  };
}

// ---- lazy production wiring (config is read on first use, so a missing secret fails the request, not the boot) ----

export function lazyServiceRpc(): Rpc {
  return { invoke: (fn, args) => supabaseRpc(serviceClient()).invoke(fn, args) };
}

export function lazyStorage(): Storage {
  const s = () => supabaseStorage(serviceClient());
  return {
    upload: (...a) => s().upload(...a),
    signedUrl: (...a) => s().signedUrl(...a),
    exists: (...a) => s().exists(...a),
    listAll: (...a) => s().listAll(...a),
    remove: (...a) => s().remove(...a),
  };
}

export function lazyAuthAdmin(): AuthAdmin {
  const a = () => supabaseAuthAdmin(serviceClient());
  return {
    getUser: (...x) => a().getUser(...x),
    deleteUser: (...x) => a().deleteUser(...x),
    setBan: (...x) => a().setBan(...x),
    invite: (...x) => a().invite(...x),
    listFactors: (...x) => a().listFactors(...x),
    deleteFactor: (...x) => a().deleteFactor(...x),
  };
}
