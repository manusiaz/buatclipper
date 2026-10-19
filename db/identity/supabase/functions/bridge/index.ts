// identity/bridge — Edge Function entrypoint (verify_jwt = false; HMAC from core or apikey from pg_cron).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY | SUPABASE_SECRET_KEYS, BRIDGE_SECRET_CORE_TO_IDENTITY,
//      BRIDGE_SECRET_IDENTITY_TO_CORE, CORE_FUNCTIONS_URL, RESEND_API_KEY, EMAIL_FROM, APP_URL, BRAND_URL, ACCOUNTS_URL,
//      VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, PII_HMAC_KEY, PII_ENC_KEYS, PII_ENC_KEY_VERSION,
//      DISBURSE_PROVIDER (xendit | mock), XENDIT_SECRET_KEY.
import { coreBridge } from "../_shared/bridge.ts";
import { piiCrypto } from "../_shared/crypto.ts";
import { lazyAuthAdmin, lazyServiceRpc } from "../_shared/db.ts";
import { providerFromEnv } from "../_shared/disburse.ts";
import { type EmailSender, resendSender } from "../_shared/email.ts";
import { env } from "../_shared/http.ts";
import { type PushSender, webPushSender } from "../_shared/push.ts";
import { type Links, linksFromEnv } from "../_shared/templates.ts";
import { createBridgeHandler } from "./handler.ts";

let email: EmailSender | undefined;
let push: Promise<PushSender> | undefined;
let links: Links | undefined;

Deno.serve(createBridgeHandler({
  secret: () => env("BRIDGE_SECRET_CORE_TO_IDENTITY"),
  rpc: lazyServiceRpc(),
  core: coreBridge,
  authAdmin: lazyAuthAdmin(),
  crypto: piiCrypto,
  email: () => (email ??= resendSender({ apiKey: env("RESEND_API_KEY"), from: env("EMAIL_FROM") })),
  push: () => (push ??= webPushSender()),
  provider: providerFromEnv,
  links: () => (links ??= linksFromEnv()),
}));
