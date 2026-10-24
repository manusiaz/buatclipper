// PII crypto (§15.4). Keys are Edge Function secrets, never database content:
//   PII_HMAC_KEY        base64, ≥ 32 bytes. HMAC-SHA256 over digits-only input → nik_hash / account_no_hash (UNIQUE, FR-04).
//   PII_ENC_KEYS        JSON {"<version>": "<base64 32-byte AES-256-GCM key>"}; old versions stay for decryption.
//   PII_ENC_KEY_VERSION current version used for new ciphertext (stored next to it as enc_key_version).
// Ciphertext layout (bytea): 12-byte IV || AES-GCM ciphertext+tag. AAD = "clipper:<purpose>" so a ciphertext of one
// kind (e.g. an account number) cannot be swapped into another column and decrypted as a NIK.
// bytea crosses PostgREST as hex text "\x…" in both directions.
import { ConfigError, HttpError } from "./http.ts";

const te = new TextEncoder();
const td = new TextDecoder();

export function b64decode(s: string): Uint8Array {
  const bin = atob(s.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64encode(u: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
  return btoa(s);
}

export function toHex(u: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u.length; i++) s += u[i].toString(16).padStart(2, "0");
  return s;
}

export function fromHex(h: string): Uint8Array {
  if (h.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(h)) throw new Error("hex tidak valid");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** bytea → PostgREST argument ("\x" + hex). */
export function toPgBytea(u: Uint8Array): string {
  return "\\x" + toHex(u);
}

/** PostgREST/jsonb bytea text ("\x…") → bytes. */
export function fromPgBytea(s: string): Uint8Array {
  if (typeof s !== "string" || !s.startsWith("\\x")) throw new Error("bytea tidak valid");
  return fromHex(s.slice(2));
}

/** Constant-time comparison for secrets/signatures (length leak only). */
export function timingSafeEqual(a: string, b: string): boolean {
  const x = te.encode(a);
  const y = te.encode(b);
  const len = Math.max(x.length, y.length);
  let diff = x.length ^ y.length;
  for (let i = 0; i < len; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function hmacKey(raw: Uint8Array): Promise<CryptoKey> {
  return await crypto.subtle.importKey("raw", raw as BufferSource, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

export async function hmacSha256(key: Uint8Array | string, msg: string): Promise<Uint8Array> {
  const k = await hmacKey(typeof key === "string" ? te.encode(key) : key);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, te.encode(msg)));
}

export async function hmacSha256Hex(key: Uint8Array | string, msg: string): Promise<string> {
  return toHex(await hmacSha256(key, msg));
}

export async function sha256Hex(msg: string): Promise<string> {
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", te.encode(msg))));
}

export function digitsOnly(s: string): string {
  return s.replace(/\D+/g, "");
}

export type Purpose = "kyc.nik" | "payout.account_no" | "recipient.data";

export interface PiiKeys {
  hmacKey: Uint8Array;
  encKeys: Map<number, Uint8Array>;
  currentVersion: number;
}

type EnvGet = (name: string) => string | undefined;

export function loadPiiKeys(get: EnvGet = (n) => Deno.env.get(n)): PiiKeys {
  const hmacRaw = get("PII_HMAC_KEY");
  if (!hmacRaw) throw new ConfigError("PII_HMAC_KEY");
  const hmacKey = b64decode(hmacRaw);
  if (hmacKey.length < 32) throw new ConfigError("PII_HMAC_KEY");

  const keysRaw = get("PII_ENC_KEYS");
  if (!keysRaw) throw new ConfigError("PII_ENC_KEYS");
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(keysRaw);
  } catch {
    throw new ConfigError("PII_ENC_KEYS");
  }
  const encKeys = new Map<number, Uint8Array>();
  for (const [ver, val] of Object.entries(parsed)) {
    const n = Number(ver);
    if (!Number.isInteger(n) || n < 1 || n > 32767 || typeof val !== "string") throw new ConfigError("PII_ENC_KEYS");
    const k = b64decode(val);
    if (k.length !== 32) throw new ConfigError("PII_ENC_KEYS");
    encKeys.set(n, k);
  }
  const currentVersion = Number(get("PII_ENC_KEY_VERSION"));
  if (!encKeys.has(currentVersion)) throw new ConfigError("PII_ENC_KEY_VERSION");
  return { hmacKey, encKeys, currentVersion };
}

export class PiiCrypto {
  #hmac?: Promise<CryptoKey>;
  #aes = new Map<number, Promise<CryptoKey>>();

  constructor(private keys: PiiKeys) {}

  get currentVersion(): number {
    return this.keys.currentVersion;
  }

  /** HMAC-SHA256 over the digits of value (spaces, dots, dashes, "+" ignored). */
  async hmac(value: string): Promise<Uint8Array> {
    const digits = digitsOnly(value);
    if (!digits) throw new HttpError(400, "invalid_input", "nilai kosong");
    this.#hmac ??= hmacKey(this.keys.hmacKey);
    return new Uint8Array(await crypto.subtle.sign("HMAC", await this.#hmac, te.encode(digits)));
  }

  /** Keyed, non-reversible short id for non-numeric values (e.g. device group = IP + user agent) sent to core. */
  async opaqueId(label: string, value: string): Promise<string> {
    this.#hmac ??= hmacKey(this.keys.hmacKey);
    const sig = await crypto.subtle.sign("HMAC", await this.#hmac, te.encode(`${label}:${value}`));
    return toHex(new Uint8Array(sig)).slice(0, 32);
  }

  #aesKey(version: number): Promise<CryptoKey> {
    const raw = this.keys.encKeys.get(version);
    if (!raw) throw new HttpError(500, "unknown_key_version", "versi kunci enkripsi tidak dikenal");
    let k = this.#aes.get(version);
    if (!k) {
      k = crypto.subtle.importKey("raw", raw as BufferSource, "AES-GCM", false, ["encrypt", "decrypt"]);
      this.#aes.set(version, k);
    }
    return k;
  }

  async encrypt(purpose: Purpose, plaintext: string): Promise<{ ciphertext: Uint8Array; version: number }> {
    const version = this.keys.currentVersion;
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: "AES-GCM", iv, additionalData: te.encode(`clipper:${purpose}`) },
        await this.#aesKey(version),
        te.encode(plaintext),
      ),
    );
    const out = new Uint8Array(12 + ct.length);
    out.set(iv, 0);
    out.set(ct, 12);
    return { ciphertext: out, version };
  }

  async decrypt(purpose: Purpose, ciphertext: Uint8Array, version: number): Promise<string> {
    if (ciphertext.length < 12 + 16) throw new HttpError(500, "corrupt_ciphertext", "data terenkripsi rusak");
    try {
      const pt = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: ciphertext.slice(0, 12), additionalData: te.encode(`clipper:${purpose}`) },
        await this.#aesKey(version),
        ciphertext.slice(12),
      );
      return td.decode(pt);
    } catch (err) {
      if (err instanceof HttpError) throw err;
      throw new HttpError(500, "corrupt_ciphertext", "data terenkripsi rusak");
    }
  }

  /** Decrypts a PostgREST bytea value ("\x…"). */
  async decryptPg(purpose: Purpose, bytea: string, version: number): Promise<string> {
    return await this.decrypt(purpose, fromPgBytea(bytea), version);
  }
}

let cached: PiiCrypto | undefined;
export function piiCrypto(): PiiCrypto {
  cached ??= new PiiCrypto(loadPiiKeys());
  return cached;
}
