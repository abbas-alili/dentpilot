// process-message — process one inbound message on demand:
//   POST { "clinic_id": "...", "message_id": "..." }  with the cron secret.
// Normally not needed: the webhook processes in the background and run-jobs
// handles reconciler retries. Useful for manual re-runs.
import { constantTimeEqual } from "../_shared/crypto.ts";
import { env, SECRETS } from "../_shared/config.ts";
import { processInbound } from "../_shared/pipeline.ts";
import { createRouterFromEnv } from "../_shared/router.ts";
import { CloudApiSender } from "../_shared/whatsapp.ts";

const cronSecret = env(SECRETS.cronSecret);
const sender = new CloudApiSender();
const router = createRouterFromEnv();

Deno.serve(async (req) => {
  if (!constantTimeEqual(req.headers.get("authorization") ?? "", `Bearer ${cronSecret}`)) {
    return new Response("unauthorized", { status: 401 });
  }
  const { clinic_id, message_id } = await req.json().catch(() => ({}));
  if (!clinic_id || !message_id) return new Response("clinic_id and message_id required", { status: 400 });
  const outcome = await processInbound({ sender, router }, clinic_id, message_id);
  return Response.json({ outcome });
});
