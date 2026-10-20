// core/bridge — lihat handler.ts. verify_jwt = false: HMAC (identity) atau apikey (pg_cron) dicek di kode.
import { requireApiKey } from "../_shared/auth.ts";
import { callBridge, identityTarget } from "../_shared/bridge.ts";
import { serviceClient, serviceRpc } from "../_shared/db.ts";
import { background, env } from "../_shared/http.ts";
import { createBridgeHandler } from "./handler.ts";

const handler = createBridgeHandler({
  rpc: (fn, args) => serviceRpc()(fn, args),
  inboundSecret: () => env("BRIDGE_SECRET_IDENTITY_TO_CORE"),
  requireApiKey,
  identity: (action, payload) => callBridge(identityTarget(), action, payload),
  removeAvatars: async (userId) => {
    const bucket = serviceClient().storage.from("avatars");
    for (;;) {
      const { data, error } = await bucket.list(userId, { limit: 100 });
      if (error) throw error;
      if (!data?.length) return;
      const { error: rmError } = await bucket.remove(data.map((f) => `${userId}/${f.name}`));
      if (rmError) throw rmError;
    }
  },
  background,
});

Deno.serve(handler);
