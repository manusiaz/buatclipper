// brand/bridge — event bus masuk dari project lain (x-bridge-from + HMAC per pengirim, lihat _shared/bus.ts).
// verify_jwt = false: autentikasi = tanda tangan HMAC.
import { handleBusDelivery } from "../_shared/bus.ts";
import { RpcError, serviceRpc } from "../_shared/db.ts";
import { HttpError, json } from "../_shared/http.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
    if (!req.headers.has("x-bridge-from")) throw new HttpError(400, "unknown_action");
    return await handleBusDelivery(req, serviceRpc());
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { ok: false, error: { code: e.code, message: e.message } });
    console.error("bridge", e instanceof RpcError ? `${e.fn} ${e.code} ${e.message}` : e);
    return json(500, { ok: false, error: { code: "internal", message: "internal error" } });
  }
});
