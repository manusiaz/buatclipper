// identity/delete-account — Edge Function entrypoint (verify_jwt = false; user JWT verified in code).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS, IDENTITY_ISSUER, IDENTITY_JWKS_URL (optional),
//      APP_ORIGINS, CORE_FUNCTIONS_URL, BRIDGE_SECRET_IDENTITY_TO_CORE.
import { verifyUserJwt } from "../_shared/auth.ts";
import { coreBridge } from "../_shared/bridge.ts";
import { lazyAuthAdmin, lazyServiceRpc, lazyStorage } from "../_shared/db.ts";
import { createDeleteAccountHandler } from "./handler.ts";

Deno.serve(createDeleteAccountHandler({
  verifyJwt: (req) => verifyUserJwt(req),
  rpc: lazyServiceRpc(),
  core: coreBridge,
  storage: lazyStorage(),
  authAdmin: lazyAuthAdmin(),
}));
