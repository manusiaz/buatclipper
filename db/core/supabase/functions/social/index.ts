// core/social — lihat handler.ts. verify_jwt = false: JWT identity diverifikasi di kode (PRD §15.6).
import { errorResponse } from "../_shared/http.ts";
import { createSocialHandler, defaultSocialDeps } from "./handler.ts";

let handler: ((req: Request) => Promise<Response>) | null = null;

Deno.serve((req) => {
  try {
    handler ??= createSocialHandler(defaultSocialDeps());
  } catch (e) {
    return errorResponse(e);
  }
  return handler(req);
});
