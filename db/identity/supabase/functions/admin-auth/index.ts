// identity/admin-auth — Edge Function entrypoint (verify_jwt = false; admin JWT aal2 verified in code).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS, IDENTITY_ISSUER, IDENTITY_JWKS_URL (optional),
//      APP_ORIGINS, ACCOUNTS_URL.
import { verifyUserJwt } from "../_shared/auth.ts";
import { lazyAuthAdmin, lazyServiceRpc } from "../_shared/db.ts";
import { env } from "../_shared/http.ts";
import { createAdminAuthHandler } from "./handler.ts";

Deno.serve(createAdminAuthHandler({
  verifyJwt: (req) => verifyUserJwt(req),
  rpc: lazyServiceRpc(),
  authAdmin: lazyAuthAdmin(),
  accountsUrl: () => env("ACCOUNTS_URL"),
}));
