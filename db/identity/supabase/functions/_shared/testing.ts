// Test doubles shared by *_test.ts files (not imported by any function entrypoint).
import type { CoreBridge } from "./bridge.ts";
import { b64encode, loadPiiKeys, PiiCrypto } from "./crypto.ts";
import type { AuthAdmin, AuthUser, Rpc, Storage } from "./db.ts";
import { HttpError } from "./http.ts";

export function testKeys(versions: Record<number, number> = { 1: 1 }, current = 1) {
  const enc: Record<string, string> = {};
  for (const [v, fill] of Object.entries(versions)) enc[v] = b64encode(new Uint8Array(32).fill(fill));
  const env: Record<string, string> = {
    PII_HMAC_KEY: b64encode(new Uint8Array(32).fill(7)),
    PII_ENC_KEYS: JSON.stringify(enc),
    PII_ENC_KEY_VERSION: String(current),
  };
  return loadPiiKeys((n) => env[n]);
}

export function testCrypto(): PiiCrypto {
  return new PiiCrypto(testKeys());
}

type RpcHandler = (args: Record<string, unknown>) => unknown;

export class FakeRpc implements Rpc {
  calls: { fn: string; args: Record<string, unknown> }[] = [];
  constructor(private handlers: Record<string, RpcHandler> = {}) {}
  on(fn: string, h: RpcHandler): this {
    this.handlers[fn] = h;
    return this;
  }
  invoke<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ fn, args });
    const h = this.handlers[fn];
    if (!h) return Promise.reject(new Error(`unexpected rpc ${fn}`));
    try {
      return Promise.resolve(h(args) as T);
    } catch (err) {
      return Promise.reject(err);
    }
  }
  named(fn: string) {
    return this.calls.filter((c) => c.fn === fn);
  }
}

export class FakeCore implements CoreBridge {
  calls: { action: string; payload: Record<string, unknown> }[] = [];
  constructor(private handlers: Record<string, (p: Record<string, unknown>) => unknown> = {}) {}
  invoke<T>(action: string, payload: Record<string, unknown>): Promise<T> {
    this.calls.push({ action, payload });
    const h = this.handlers[action];
    if (!h) return Promise.reject(new HttpError(400, "unknown_action", action));
    try {
      return Promise.resolve(h(payload) as T);
    } catch (err) {
      return Promise.reject(err);
    }
  }
  named(action: string) {
    return this.calls.filter((c) => c.action === action);
  }
}

export class FakeStorage implements Storage {
  files = new Map<string, { body: Uint8Array; contentType: string }>();
  upload(bucket: string, path: string, body: Uint8Array, contentType: string, upsert: boolean): Promise<void> {
    const key = `${bucket}/${path}`;
    if (!upsert && this.files.has(key)) return Promise.reject(new HttpError(409, "file_exists", "exists"));
    this.files.set(key, { body, contentType });
    return Promise.resolve();
  }
  signedUrl(bucket: string, path: string, expiresIn: number): Promise<string> {
    return Promise.resolve(`https://storage.test/${bucket}/${path}?ttl=${expiresIn}`);
  }
  exists(bucket: string, path: string): Promise<boolean> {
    return Promise.resolve(this.files.has(`${bucket}/${path}`));
  }
  listAll(bucket: string, prefix: string): Promise<string[]> {
    const p = `${bucket}/${prefix.replace(/\/+$/, "")}/`;
    return Promise.resolve(
      [...this.files.keys()].filter((k) => k.startsWith(p)).map((k) => k.slice(bucket.length + 1)),
    );
  }
  remove(bucket: string, paths: string[]): Promise<void> {
    for (const p of paths) this.files.delete(`${bucket}/${p}`);
    return Promise.resolve();
  }
  text(key: string): string {
    return new TextDecoder().decode(this.files.get(key)!.body);
  }
}

export class FakeAuthAdmin implements AuthAdmin {
  users = new Map<string, AuthUser>();
  factors = new Map<string, string[]>();
  bans: { id: string; duration: string }[] = [];
  deleted: string[] = [];
  getUser(id: string) {
    return Promise.resolve(this.users.get(id) ?? null);
  }
  deleteUser(id: string) {
    this.deleted.push(id);
    this.users.delete(id);
    return Promise.resolve();
  }
  setBan(id: string, duration: string) {
    this.bans.push({ id, duration });
    const banned_until = duration === "none" ? null : new Date(Date.now() + 3600_000).toISOString();
    this.users.set(id, { ...(this.users.get(id) ?? { id }), banned_until });
    return Promise.resolve({ id, banned_until });
  }
  invites: { email: string; redirectTo: string; data: Record<string, unknown> }[] = [];
  invite(email: string, redirectTo: string, data: Record<string, unknown>): Promise<AuthUser> {
    const id: string = crypto.randomUUID();
    this.invites.push({ email, redirectTo, data });
    this.users.set(id, { id, email });
    return Promise.resolve({ id });
  }
  listFactors(userId: string) {
    return Promise.resolve((this.factors.get(userId) ?? []).map((id) => ({ id })));
  }
  deleteFactor(userId: string, factorId: string) {
    this.factors.set(userId, (this.factors.get(userId) ?? []).filter((f) => f !== factorId));
    return Promise.resolve();
  }
  magicLinks: string[] = [];
  magicLink(email: string) {
    this.magicLinks.push(email);
    return Promise.resolve(`hash-${this.magicLinks.length}`);
  }
}

export function claims(sub: string, opts: { aal?: string; roles?: string[] } = {}) {
  return { sub, aal: opts.aal ?? "aal1", app_roles: opts.roles ?? [], kyc: "none", token: "user.jwt.token" };
}

export function post(body: unknown, headers: Record<string, string> = {}, url = "http://localhost/fn"): Request {
  return new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// deno-lint-ignore no-explicit-any
export async function json(res: Response): Promise<{ status: number; body: any }> {
  return { status: res.status, body: await res.json() };
}
