// core/bridge — lihat handler.ts. verify_jwt = false: HMAC (identity) atau apikey (pg_cron) dicek di kode.
import { requireApiKey } from "../_shared/auth.ts";
import { callBridge, identityTarget } from "../_shared/bridge.ts";
import { serviceRpc } from "../_shared/db.ts";
import { background, env } from "../_shared/http.ts";
import { createBridgeHandler } from "./handler.ts";

const handler = createBridgeHandler({
  rpc: (fn, args) => serviceRpc()(fn, args),
  inboundSecret: () => env("BRIDGE_SECRET_IDENTITY_TO_CORE"),
  requireApiKey,
  identity: (action, payload) => callBridge(identityTarget(), action, payload),
  background,
});

Deno.serve(handler);
