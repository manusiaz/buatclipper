// identity/session-handoff — Edge Function entrypoint (verify_jwt = false; create: JWT user diverifikasi di kode lewat
// JWKS, redeem: apikey publishable). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS,
//      SUPABASE_ANON_KEY | SUPABASE_PUBLISHABLE_KEYS, IDENTITY_ISSUER, IDENTITY_JWKS_URL (optional), APP_ORIGINS,
//      ACCOUNTS_URL, APP_URL, BRAND_URL.
import { isPublishableRequest, verifyUserJwt } from "../_shared/auth.ts";
import { lazyAuthAdmin, lazyServiceRpc } from "../_shared/db.ts";
import { type Links, linksFromEnv } from "../_shared/templates.ts";
import { createSessionHandoffHandler } from "./handler.ts";

let links: Links | undefined;

Deno.serve(createSessionHandoffHandler({
  verifyJwt: (req) => verifyUserJwt(req),
  isPublishable: isPublishableRequest,
  rpc: lazyServiceRpc(),
  authAdmin: lazyAuthAdmin(),
  links: () => (links ??= linksFromEnv()),
}));
