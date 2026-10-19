// HTTP plumbing shared by every identity Edge Function: error envelope, CORS, body limits, input validation,
// structured logs. Response envelope (same as the bridge protocol): {"ok":true,"data":…} / {"ok":false,"error":{code,message}}.
// Logs never contain request bodies, DB error messages or PII (§15.9): only function, action, outcome, error code.

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
    this.name = "HttpError";
  }
}

export class ConfigError extends HttpError {
  constructor(public variable: string) {
    super(500, "config_missing", "server belum dikonfigurasi");
    this.name = "ConfigError";
  }
}

export function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new ConfigError(name);
  return v;
}

export function envOpt(name: string): string | undefined {
  return Deno.env.get(name) || undefined;
}

/** JSON env var whose values are strings, e.g. SUPABASE_SECRET_KEYS = {"default":"sb_secret_…"}. */
export function envJsonValues(name: string): string[] {
  const raw = Deno.env.get(name);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      return Object.values(parsed).filter((v): v is string => typeof v === "string" && v.length > 0);
    }
  } catch {
    // malformed JSON → treated as absent
  }
  return [];
}

export function jsonResponse(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  const h = new Headers(headers);
  h.set("content-type", "application/json; charset=utf-8");
  h.set("cache-control", "no-store");
  return new Response(JSON.stringify(body), { status, headers: h });
}

export function okResponse(data: unknown, status = 200): Response {
  return jsonResponse({ ok: true, data }, status);
}

export function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse({ ok: false, error: { code, message } }, status);
}

export function log(level: "info" | "warn" | "error", fields: Record<string, unknown>): void {
  const line = JSON.stringify({ level, at: new Date().toISOString(), ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

/** Allowed browser origins from APP_ORIGINS (comma separated, exact match). */
export function allowedOrigins(): string[] {
  return (Deno.env.get("APP_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

function applyCors(req: Request, res: Response): Response {
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins().includes(origin)) return res;
  const h = new Headers(res.headers);
  h.set("access-control-allow-origin", origin);
  h.set("vary", "Origin");
  h.set("access-control-expose-headers", "x-correlation-id");
  return new Response(res.body, { status: res.status, headers: h });
}

function preflight(req: Request): Response {
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins().includes(origin)) return new Response(null, { status: 403 });
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": origin,
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "authorization, content-type, x-client-info, apikey, x-correlation-id",
      "access-control-max-age": "600",
      vary: "Origin",
    },
  });
}

export interface ServeOptions {
  fn: string;
  cors?: boolean;
}

/** Wraps a handler: CORS, correlation id, error envelope; unknown errors become 500 without leaking details. */
export function wrap(
  opts: ServeOptions,
  handler: (req: Request, ctx: { correlationId: string }) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (opts.cors && req.method === "OPTIONS") return preflight(req);
    const inbound = req.headers.get("x-correlation-id") ?? "";
    const correlationId = /^[A-Za-z0-9-]{8,64}$/.test(inbound) ? inbound : crypto.randomUUID();
    let res: Response;
    try {
      res = await handler(req, { correlationId });
    } catch (err) {
      if (err instanceof ConfigError) {
        log("error", { fn: opts.fn, correlationId, code: err.code, variable: err.variable });
        res = errorResponse(err.status, err.code, err.message);
      } else if (err instanceof HttpError) {
        log(err.status >= 500 ? "error" : "info", { fn: opts.fn, correlationId, status: err.status, code: err.code });
        res = errorResponse(err.status, err.code, err.message);
      } else {
        log("error", { fn: opts.fn, correlationId, code: "internal", error: (err as Error)?.name ?? "unknown" });
        res = errorResponse(500, "internal", "terjadi kesalahan, coba lagi");
      }
    }
    const h = new Headers(res.headers);
    h.set("x-correlation-id", correlationId);
    res = new Response(res.body, { status: res.status, headers: h });
    return opts.cors ? applyCors(req, res) : res;
  };
}

/** Reads the raw body with a size cap (bridge needs the exact bytes for the HMAC). */
export async function readRaw(req: Request, maxBytes: number): Promise<string> {
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed", "hanya POST");
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > maxBytes) throw new HttpError(413, "payload_too_large", "body terlalu besar");
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.byteLength > maxBytes) throw new HttpError(413, "payload_too_large", "body terlalu besar");
  return new TextDecoder().decode(buf);
}

export function parseJsonObject(raw: string): Record<string, unknown> {
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "invalid_json", "body bukan JSON");
  }
  return obj(v, "body");
}

export async function readJson(req: Request, maxBytes = 64 * 1024): Promise<Record<string, unknown>> {
  return parseJsonObject(await readRaw(req, maxBytes));
}

// ---- input validation -------------------------------------------------------------------------------------------

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

export function obj(v: unknown, name: string): Record<string, unknown> {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new HttpError(400, "invalid_input", `${name} harus objek`);
  return v as Record<string, unknown>;
}

export function str(
  o: Record<string, unknown>,
  key: string,
  opts: { min?: number; max?: number; pattern?: RegExp; optional?: boolean } = {},
): string {
  const v = o[key];
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return "";
    throw new HttpError(400, "invalid_input", `${key} wajib diisi`);
  }
  if (typeof v !== "string") throw new HttpError(400, "invalid_input", `${key} harus teks`);
  if (opts.min !== undefined && v.length < opts.min) throw new HttpError(400, "invalid_input", `${key} terlalu pendek`);
  if (opts.max !== undefined && v.length > opts.max) {
    throw new HttpError(400, "invalid_input", `${key} terlalu panjang`);
  }
  if (opts.pattern && !opts.pattern.test(v)) throw new HttpError(400, "invalid_input", `${key} tidak valid`);
  return v;
}

export function uuid(o: Record<string, unknown>, key: string): string {
  const v = o[key];
  if (!isUuid(v)) throw new HttpError(400, "invalid_input", `${key} harus UUID`);
  return v.toLowerCase();
}

export function uuidList(o: Record<string, unknown>, key: string, max: number): string[] {
  const v = o[key] ?? [];
  if (!Array.isArray(v)) throw new HttpError(400, "invalid_input", `${key} harus array`);
  if (v.length > max) throw new HttpError(413, "payload_too_large", `${key} maksimal ${max}`);
  return v.map((x) => {
    if (!isUuid(x)) throw new HttpError(400, "invalid_input", `${key} berisi bukan UUID`);
    return x.toLowerCase();
  });
}

export function action(o: Record<string, unknown>): string {
  return str(o, "action", { max: 64, pattern: /^[a-z][a-z0-9_]*$/ });
}
