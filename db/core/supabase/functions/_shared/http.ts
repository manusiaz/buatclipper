// Respons JSON, error bertipe, CORS, dan helper crypto kecil yang dipakai semua Edge Function core.

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message = code,
    public detail?: unknown,
  ) {
    super(message);
  }
}

export function json(status: number, body: unknown, headers: HeadersInit = {}): Response {
  const h = new Headers(headers);
  h.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers: h });
}

/** Error → respons. Error tak dikenal tidak membocorkan pesan internal. */
export function errorResponse(e: unknown, headers: HeadersInit = {}): Response {
  if (e instanceof HttpError) {
    return json(e.status, { error: e.code, message: e.message, ...(e.detail === undefined ? {} : { detail: e.detail }) }, headers);
  }
  console.error("unhandled", e instanceof Error ? e.stack ?? e.message : e);
  return json(500, { error: "internal", message: "internal error" }, headers);
}

export async function readJson<T = Record<string, unknown>>(req: Request, maxBytes = 64 * 1024): Promise<T> {
  const text = await req.text();
  if (text.length > maxBytes) throw new HttpError(413, "payload_too_large");
  try {
    const v = JSON.parse(text || "{}");
    if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    return v as T;
  } catch {
    throw new HttpError(400, "bad_json");
  }
}

export function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new HttpError(500, "misconfigured", `env ${name} belum diset`);
  return v;
}

export function envList(name: string): string[] {
  return (Deno.env.get(name) ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

/** CORS: hanya origin di APP_ORIGINS. Panggilan server-ke-server (tanpa Origin) tidak butuh header CORS. */
export function corsHeaders(req: Request, allowed: string[]): { ok: boolean; headers: Headers } {
  const origin = req.headers.get("origin");
  const headers = new Headers({ vary: "Origin" });
  if (!origin) return { ok: true, headers };
  if (!allowed.includes(origin)) return { ok: false, headers };
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-methods", "POST, OPTIONS");
  headers.set("access-control-allow-headers", "authorization, content-type, x-client-info, apikey");
  headers.set("access-control-max-age", "600");
  return { ok: true, headers };
}

const enc = new TextEncoder();

export function toHex(buf: ArrayBuffer | Uint8Array): string {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
}

/** Perbandingan waktu-konstan: kedua sisi di-hash dulu supaya panjang berbeda tidak bocor lewat waktu. */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha), y = new Uint8Array(hb);
  let diff = a.length === b.length ? 0 : 1;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomToken(bytes = 32): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

/** Jalankan tugas di latar (pg_net menunggu respons maks 5 detik); tanpa EdgeRuntime (tes/lokal) ditunggu langsung. */
export async function background<T>(task: Promise<T>, sync: boolean): Promise<{ result?: T; accepted: boolean }> {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (!sync && rt?.waitUntil) {
    rt.waitUntil(task.catch((e: unknown) => console.error("background task failed", e)));
    return { accepted: true };
  }
  return { result: await task, accepted: false };
}
