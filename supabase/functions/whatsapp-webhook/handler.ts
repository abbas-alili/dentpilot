// whatsapp-webhook — receives every WhatsApp event for every clinic.
// Connects as dentpilot_agent (SOP §5b).
//
//   GET   subscription handshake (hub.verify_token → hub.challenge)
//   POST  1. verify X-Hub-Signature-256 (reject unsigned/forged calls)
//         2. resolve clinic from metadata.phone_number_id (unknown → log, 200)
//         3. record messages / echoes / delivery statuses (idempotent)
//         4. answer 200 at once; process new inbound messages in the background
//   A database error returns 500 so Meta retries; dedup makes retries safe.
//   Anything not processed in the background is picked up by the reconciler.

import { clinicForPhoneNumber, withClinic } from "../_shared/db.ts";
import { verifyMetaSignature } from "../_shared/crypto.ts";
import { log } from "../_shared/log.ts";
import { type PipelineDeps, processInbound } from "../_shared/pipeline.ts";
import { parseWebhook, type WebhookEvent } from "../_shared/webhook_parse.ts";

export interface WebhookDeps extends PipelineDeps {
  appSecret: string;
  verifyToken: string;
  /** Keeps work alive after the response (EdgeRuntime.waitUntil in production). */
  background: (work: Promise<unknown>) => void;
}

export function createWebhookHandler(deps: WebhookDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "GET") return verifySubscription(req, deps.verifyToken);
    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

    const raw = await req.text();
    if (!(await verifyMetaSignature(deps.appSecret, raw, req.headers.get("x-hub-signature-256")))) {
      log.warn("webhook.bad_signature");
      return new Response("invalid signature", { status: 401 });
    }

    let payload: unknown;
    try {
      payload = JSON.parse(raw);
    } catch {
      return new Response("bad json", { status: 400 });
    }

    let toProcess: { clinicId: string; messageId: string }[];
    try {
      toProcess = await record(parseWebhook(payload));
    } catch (error) {
      log.error("webhook.record_failed", { error: String(error) });
      return new Response("retry", { status: 500 });
    }

    if (toProcess.length) deps.background(processAll(deps, toProcess));
    return new Response("ok", { status: 200 });
  };
}

function verifySubscription(req: Request, verifyToken: string): Response {
  const url = new URL(req.url);
  if (url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === verifyToken) {
    return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
  }
  return new Response("forbidden", { status: 403 });
}

/** Records every event; returns the new (non-duplicate) inbound messages to process. */
async function record(events: WebhookEvent[]): Promise<{ clinicId: string; messageId: string }[]> {
  const clinics = new Map<string, string | null>();
  const fresh: { clinicId: string; messageId: string }[] = [];

  for (const event of events) {
    if (!clinics.has(event.phoneNumberId)) {
      clinics.set(event.phoneNumberId, await clinicForPhoneNumber(event.phoneNumberId));
    }
    const clinicId = clinics.get(event.phoneNumberId);
    if (!clinicId) {
      log.warn("webhook.unknown_phone_number", { phoneNumberId: event.phoneNumberId });
      continue;
    }

    await withClinic(clinicId, async (tx) => {
      switch (event.type) {
        case "inbound": {
          const [row] = await tx`
            select message_id, is_duplicate from core.record_inbound_message(
              ${event.waMessageId}, ${event.waId}, ${event.kind}, ${event.body}, ${event.mediaId},
              ${event.mediaMime}, ${event.sentAt}, ${event.replyTo}, ${event.profileName})`;
          if (!row.is_duplicate) fresh.push({ clinicId, messageId: row.message_id });
          break;
        }
        case "echo":
          await tx`select core.record_echo_message(${event.waMessageId}, ${event.patientWaId},
                                                   ${event.kind}, ${event.body}, ${event.sentAt})`;
          break;
        case "status":
          await tx`select core.update_delivery_status(${event.waMessageId}, ${event.status}, ${event.error})`;
          break;
      }
    });
  }
  return fresh;
}

/** In arrival order, so a patient's messages are answered in sequence. */
async function processAll(deps: PipelineDeps, items: { clinicId: string; messageId: string }[]): Promise<void> {
  for (const item of items) {
    try {
      await processInbound(deps, item.clinicId, item.messageId);
    } catch (error) {
      // The reconciler retries it within ~1 minute.
      log.error("webhook.process_failed", { messageId: item.messageId, error: String(error) });
    }
  }
}
