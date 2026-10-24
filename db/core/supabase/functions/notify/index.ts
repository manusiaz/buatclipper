// core/notify — POST (pg_cron notify-drain, header apikey) menguras queue email;
// GET/POST /notify/unsubscribe?u=&s= publik (HMAC UNSUBSCRIBE_SECRET) untuk one-click unsubscribe email promosi.
import { requireApiKey } from "../_shared/auth.ts";
import { callBridge, identityTarget } from "../_shared/bridge.ts";
import { serviceRpc } from "../_shared/db.ts";
import { background, env, errorResponse, HttpError, json } from "../_shared/http.ts";
import { handleUnsubscribe, runNotify } from "./notify.ts";

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    if (url.pathname.replace(/\/+$/, "").endsWith("/unsubscribe")) {
      return await handleUnsubscribe(req, { rpc: serviceRpc(), unsubscribeSecret: env("UNSUBSCRIBE_SECRET") });
    }
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
    await requireApiKey(req);
    await req.body?.cancel();
    const target = identityTarget();
    const run = runNotify({
      rpc: serviceRpc(),
      bridge: (action, payload) => callBridge(target, action, payload),
      unsubscribeSecret: env("UNSUBSCRIBE_SECRET"),
      unsubscribeBase: Deno.env.get("UNSUBSCRIBE_BASE_URL") ?? `${env("SUPABASE_URL")}/functions/v1/notify/unsubscribe`,
    });
    const out = await background(run, url.searchParams.get("sync") === "1");
    return out.accepted ? json(202, { accepted: true }) : json(200, out.result);
  } catch (e) {
    return errorResponse(e);
  }
});
