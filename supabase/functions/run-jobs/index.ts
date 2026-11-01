// Entry point. Deploy with JWT verification off; the handler checks the cron
// secret (Authorization: Bearer <DENTPILOT_CRON_SECRET>) sent by pg_cron.
import { env, SECRETS } from "../_shared/config.ts";
import { GoogleCalendarClient } from "../_shared/gcal.ts";
import { WebPushSender } from "../_shared/push.ts";
import { createRouterFromEnv } from "../_shared/router.ts";
import { CloudApiSender } from "../_shared/whatsapp.ts";
import { createJobsHandler } from "./handler.ts";

Deno.serve(createJobsHandler({
  cronSecret: env(SECRETS.cronSecret),
  sender: new CloudApiSender(),
  router: createRouterFromEnv(),
  push: new WebPushSender(),
  google: Deno.env.get("GOOGLE_CLIENT_ID") ? new GoogleCalendarClient() : undefined,
}));
