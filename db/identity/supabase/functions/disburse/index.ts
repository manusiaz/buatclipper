// identity/disburse — provider webhook for instant withdraw (alur 11): POST /disburse/callback, header x-callback-token.
// The disbursement itself is started by core through the identity bridge (action "disburse", same module).
// Env: CORE_FUNCTIONS_URL, BRIDGE_SECRET_IDENTITY_TO_CORE, DISBURSE_CALLBACK_TOKEN, DISBURSE_PROVIDER (xendit | mock),
//      XENDIT_SECRET_KEY.
import { coreBridge } from "../_shared/bridge.ts";
import { handleCallback, providerFromEnv } from "../_shared/disburse.ts";
import { env, HttpError, okResponse, readRaw, wrap } from "../_shared/http.ts";

Deno.serve(wrap({ fn: "disburse" }, async (req) => {
  if (!new URL(req.url).pathname.endsWith("/callback")) throw new HttpError(404, "not_found", "route tidak ada");
  const raw = await readRaw(req, 64 * 1024);
  return okResponse(
    await handleCallback(
      { core: coreBridge, provider: providerFromEnv, token: () => env("DISBURSE_CALLBACK_TOKEN") },
      req.headers,
      raw,
    ),
  );
}));
