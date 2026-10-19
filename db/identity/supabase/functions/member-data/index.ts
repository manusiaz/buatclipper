// identity/member-data — Edge Function entrypoint (verify_jwt = false; the user JWT is verified in code via JWKS).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS, SUPABASE_ANON_KEY | SUPABASE_PUBLISHABLE_KEYS,
//      IDENTITY_ISSUER, IDENTITY_JWKS_URL (optional), APP_ORIGINS, PII_HMAC_KEY, PII_ENC_KEYS, PII_ENC_KEY_VERSION.
import { verifyUserJwt } from "../_shared/auth.ts";
import { piiCrypto } from "../_shared/crypto.ts";
import { lazyServiceRpc, lazyStorage, userRpc } from "../_shared/db.ts";
import { createMemberDataHandler } from "./handler.ts";

Deno.serve(createMemberDataHandler({
  verifyJwt: (req) => verifyUserJwt(req),
  rpc: lazyServiceRpc(),
  userRpc,
  storage: lazyStorage(),
  crypto: piiCrypto,
}));
