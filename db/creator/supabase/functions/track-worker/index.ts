// creator/track-worker — dipicu pg_cron tiap 5 menit lewat ops.invoke_function (header apikey = secret key creator).
// Respons 202 langsung (pg_net menunggu maks 5 detik), kerja lanjut di EdgeRuntime.waitUntil. ?sync=1 = tunggu hasil.
import { requireApiKey } from "../_shared/auth.ts";
import { serviceRpc } from "../_shared/db.ts";
import { background, errorResponse, HttpError, json } from "../_shared/http.ts";
import { adapterFor, platformFlags } from "../_shared/social/mod.ts";
import { runTrackWorker } from "./worker.ts";

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
    await requireApiKey(req);
    await req.body?.cancel();
    const run = runTrackWorker({ rpc: serviceRpc(), adapter: (p) => adapterFor(p), flags: () => platformFlags() });
    const out = await background(run, new URL(req.url).searchParams.get("sync") === "1");
    return out.accepted ? json(202, { accepted: true }) : json(200, out.result);
  } catch (e) {
    return errorResponse(e);
  }
});
