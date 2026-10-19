// core/refresh-tokens — dipicu pg_cron (job token-refresh, tiap 6 jam) dengan header apikey = secret key core.
import { requireApiKey } from "../_shared/auth.ts";
import { serviceRpc } from "../_shared/db.ts";
import { background, errorResponse, HttpError, json } from "../_shared/http.ts";
import { adapterFor } from "../_shared/social/mod.ts";
import { runRefresh } from "./refresh.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
    await requireApiKey(req);
    await req.body?.cancel();
    const out = await background(
      runRefresh({ rpc: serviceRpc(), adapter: (p) => adapterFor(p) }),
      new URL(req.url).searchParams.get("sync") === "1",
    );
    return out.accepted ? json(202, { accepted: true }) : json(200, out.result);
  } catch (e) {
    return errorResponse(e);
  }
});
