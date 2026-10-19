// identity/pii-export — Edge Function entrypoint (verify_jwt = false; admin JWT aal2 verified in code).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS, IDENTITY_ISSUER, IDENTITY_JWKS_URL (optional),
//      APP_ORIGINS, PII_HMAC_KEY, PII_ENC_KEYS, PII_ENC_KEY_VERSION, CORE_FUNCTIONS_URL, BRIDGE_SECRET_IDENTITY_TO_CORE.
import { verifyUserJwt } from "../_shared/auth.ts";
import { coreBridge } from "../_shared/bridge.ts";
import { piiCrypto } from "../_shared/crypto.ts";
import { lazyServiceRpc, lazyStorage } from "../_shared/db.ts";
import { createPiiExportHandler } from "./handler.ts";

Deno.serve(createPiiExportHandler({
  verifyJwt: (req) => verifyUserJwt(req),
  rpc: lazyServiceRpc(),
  core: coreBridge,
  storage: lazyStorage(),
  crypto: piiCrypto,
}));
