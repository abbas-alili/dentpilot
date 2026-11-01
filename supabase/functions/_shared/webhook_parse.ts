// Turns a WhatsApp Cloud API webhook payload into plain events.
// Pure function — no I/O — so it is unit-tested against sample payloads.
//
// Interactive replies are stored by their machine id (e.g. "menu:book"),
// which is what the pipeline routes on; Flow completions keep the raw
// response_json. Echoes come from the Coexistence "smb_message_echoes" field.
// VERIFY the echo payload shape against Meta's current Coexistence docs when
// connecting the number — it is the least-documented part of this file.

export interface InboundEvent {
  type: "inbound";
  phoneNumberId: string;
  waMessageId: string;
  waId: string;
  profileName: string | null;
  kind: string;
  body: string | null;
  mediaId: string | null;
  mediaMime: string | null;
  sentAt: Date | null;
  replyTo: string | null;
}

export interface EchoEvent {
  type: "echo";
  phoneNumberId: string;
  waMessageId: string;
  patientWaId: string;
  kind: string;
  body: string | null;
  sentAt: Date | null;
}

export interface StatusEvent {
  type: "status";
  phoneNumberId: string;
  waMessageId: string;
  status: "sent" | "delivered" | "read" | "failed";
  error: string | null;
}

export type WebhookEvent = InboundEvent | EchoEvent | StatusEvent;

// deno-lint-ignore no-explicit-any
type Json = any;

const KNOWN_STATUSES = new Set(["sent", "delivered", "read", "failed"]);
const MEDIA = new Set(["image", "audio", "video", "document", "sticker"]);

export function parseWebhook(payload: Json): WebhookEvent[] {
  const events: WebhookEvent[] = [];
  for (const entry of payload?.entry ?? []) {
    for (const change of entry?.changes ?? []) {
      const value = change?.value ?? {};
      const phoneNumberId = value?.metadata?.phone_number_id;
      if (!phoneNumberId) continue;

      if (change.field === "messages") {
        const names = new Map<string, string>(
          (value.contacts ?? []).map((c: Json) => [c.wa_id, c.profile?.name ?? null]),
        );
        for (const m of value.messages ?? []) {
          events.push({ type: "inbound", phoneNumberId, ...inbound(m), profileName: names.get(m.from) ?? null });
        }
        for (const s of value.statuses ?? []) {
          if (!KNOWN_STATUSES.has(s.status)) continue;
          const err = s.errors?.[0];
          events.push({
            type: "status", phoneNumberId, waMessageId: s.id, status: s.status,
            error: err ? `${err.code ?? ""} ${err.title ?? err.message ?? ""}`.trim() : null,
          });
        }
      }

      if (change.field === "smb_message_echoes") {
        for (const m of value.message_echoes ?? []) {
          const parsed = inbound(m);
          events.push({
            type: "echo", phoneNumberId, waMessageId: parsed.waMessageId,
            patientWaId: m.to, kind: parsed.kind, body: parsed.body, sentAt: parsed.sentAt,
          });
        }
      }
    }
  }
  return events;
}

function inbound(m: Json): Omit<InboundEvent, "type" | "phoneNumberId" | "profileName"> {
  const base = {
    waMessageId: String(m.id),
    waId: String(m.from),
    sentAt: m.timestamp ? new Date(Number(m.timestamp) * 1000) : null,
    replyTo: m.context?.id ?? null,
    mediaId: null as string | null,
    mediaMime: null as string | null,
  };

  switch (m.type) {
    case "text":
      return { ...base, kind: "text", body: m.text?.body ?? "" };
    case "interactive": {
      const i = m.interactive ?? {};
      if (i.type === "nfm_reply") return { ...base, kind: "flow_reply", body: i.nfm_reply?.response_json ?? "{}" };
      if (i.type === "button_reply") return { ...base, kind: "interactive", body: i.button_reply?.id ?? "" };
      if (i.type === "list_reply") return { ...base, kind: "interactive", body: i.list_reply?.id ?? "" };
      return { ...base, kind: "unsupported", body: null };
    }
    case "button":   // quick reply on a template message
      return { ...base, kind: "interactive", body: m.button?.payload ?? "" };
    case "location":
      return { ...base, kind: "location", body: null };
    case "reaction":
      return { ...base, kind: "reaction", body: m.reaction?.emoji ?? null };
    default:
      if (MEDIA.has(m.type)) {
        const media = m[m.type] ?? {};
        return { ...base, kind: m.type, body: media.caption ?? null, mediaId: media.id ?? null, mediaMime: media.mime_type ?? null };
      }
      return { ...base, kind: "unsupported", body: null };
  }
}
