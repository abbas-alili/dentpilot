// Record first, send second (SOP §5b):
//   1. queue_outbound_message (idempotent on send_key) — commit
//      In shadow mode the row is a DRAFT: nothing is sent; staff approve it
//      in the web app, which queues a 'send_message' job → sendQueued().
//   2. call the Cloud API (outside any transaction)
//   3. mark_outbound_sent / mark_outbound_failed — commit
// A retry with the same send_key never sends a message Meta already accepted.

import { withClinic } from "./db.ts";
import type { OutboundMessage, WhatsAppSender } from "./whatsapp.ts";

export type OutcomeStatus = "sent" | "drafted" | "already_sent";

export interface OutboundRequest {
  clinicId: string;
  patientId: string;
  message: OutboundMessage;
  /** Stable key for this send; same key = same message (never sent twice). */
  sendKey: string;
  source?: "assistant" | "system";
}

/** Text stored in core.messages for the staff inbox (no secrets, readable). */
function describe(message: OutboundMessage): { kind: string; body: string | null; templateName: string | null } {
  switch (message.type) {
    case "text":
      return { kind: "text", body: message.text.body, templateName: null };
    case "template":
      return { kind: "template", body: null, templateName: String(message.template.name) };
    case "interactive": {
      const body = (message.interactive.body as { text?: string } | undefined)?.text ?? null;
      return { kind: "interactive", body, templateName: null };
    }
  }
}

export async function sendRecorded(sender: WhatsAppSender, request: OutboundRequest): Promise<OutcomeStatus> {
  const { kind, body, templateName } = describe(request.message);

  const [queued] = await withClinic(request.clinicId, (tx) =>
    tx`select message_id, delivery_status
         from core.queue_outbound_message(${request.patientId}, ${request.source ?? "assistant"}, ${kind},
                                          ${body}, ${templateName}, ${request.sendKey},
                                          ${tx.json(request.message as never)})`
  );
  if (!queued) throw new Error(`outbound: could not queue for patient ${request.patientId}`);
  if (queued.delivery_status === "draft") return "drafted";
  return await sendQueued(sender, request.clinicId, queued.message_id);
}

/**
 * Send one recorded outbound message (pending or failed) by id.
 * Used right after queueing, and by run-jobs for approved drafts and staff replies.
 */
export async function sendQueued(sender: WhatsAppSender, clinicId: string, messageId: string): Promise<OutcomeStatus> {
  const [row] = await withClinic(clinicId, (tx) =>
    tx`select m.delivery_status, m.outbound_payload, c.wa_phone_number_id, p.wa_id
         from core.messages m
         join core.patients p on p.id = m.patient_id
         join core.clinics  c on c.id = m.clinic_id
        where m.id = ${messageId} and m.direction = 'out'`
  );
  if (!row) throw new Error(`outbound: message ${messageId} not found`);
  if (!["pending", "failed"].includes(row.delivery_status)) return "already_sent";   // sent, draft, discarded…
  if (!row.outbound_payload) throw new Error(`outbound: message ${messageId} has no payload`);
  if (!row.wa_phone_number_id) throw new Error("outbound: clinic has no wa_phone_number_id");

  const result = await sender.send(row.wa_phone_number_id, row.wa_id, row.outbound_payload as OutboundMessage);

  if (result.ok) {
    await withClinic(clinicId, (tx) => tx`select core.mark_outbound_sent(${messageId}, ${result.wamid})`);
    return "sent";
  }
  if (result.definite) {
    await withClinic(clinicId, (tx) => tx`select core.mark_outbound_failed(${messageId}, ${result.error})`);
  }
  // Not definite (timeout): leave it 'pending'. A retry will send again — a rare
  // duplicate is preferred over a lost confirmation.
  throw new Error(`outbound send failed (${result.definite ? "rejected" : "unknown"}): ${result.error}`);
}
