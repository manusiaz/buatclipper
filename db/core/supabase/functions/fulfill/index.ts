// core/fulfill — dipicu pg_cron (fulfillment-retry, tiap 5 menit) dengan header apikey = secret key core.
import { requireApiKey } from "../_shared/auth.ts";
import { serviceRpc } from "../_shared/db.ts";
import { background, errorResponse, HttpError, json } from "../_shared/http.ts";
import { runFulfill } from "./fulfill.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
    await requireApiKey(req);
    await req.body?.cancel();
    const out = await background(runFulfill({ rpc: serviceRpc() }), new URL(req.url).searchParams.get("sync") === "1");
    return out.accepted ? json(202, { accepted: true }) : json(200, out.result);
  } catch (e) {
    return errorResponse(e);
  }
});
