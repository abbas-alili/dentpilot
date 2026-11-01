// Entry point. Deploy with JWT verification off (Meta can't send a Supabase JWT);
// authenticity comes from the X-Hub-Signature-256 check in the handler.
import { env, SECRETS } from "../_shared/config.ts";
import { createRouterFromEnv } from "../_shared/router.ts";
import { runInBackground } from "../_shared/runtime.ts";
import { CloudApiSender } from "../_shared/whatsapp.ts";
import { createWebhookHandler } from "./handler.ts";

Deno.serve(createWebhookHandler({
  appSecret: env(SECRETS.waAppSecret),
  verifyToken: env(SECRETS.waVerifyToken),
  sender: new CloudApiSender(),
  router: createRouterFromEnv(),   // LLM_PROVIDER=none → menu only
  background: runInBackground,
}));
