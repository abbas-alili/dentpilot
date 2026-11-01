// WhatsApp Cloud API: message builders and a sender.
// The sender is an interface so tests (and a future dry-run mode) can swap in
// a fake that records messages instead of calling Meta.

import { env, SECRETS } from "./config.ts";

// ---------------------------------------------------------------- message shapes
export type OutboundMessage =
  | { type: "text"; text: { body: string; preview_url?: boolean } }
  | { type: "interactive"; interactive: Record<string, unknown> }
  | { type: "template"; template: Record<string, unknown> };

export interface Button { id: string; title: string }           // title ≤ 20 chars
export interface ListRow { id: string; title: string; description?: string } // title ≤ 24

export const wa = {
  text(body: string): OutboundMessage {
    return { type: "text", text: { body, preview_url: false } };
  },

  /** Up to 3 reply buttons. */
  buttons(body: string, buttons: Button[]): OutboundMessage {
    return {
      type: "interactive",
      interactive: {
        type: "button",
        body: { text: body },
        action: { buttons: buttons.map((b) => ({ type: "reply", reply: { id: b.id, title: b.title } })) },
      },
    };
  },

  /** A list (menu) of up to 10 rows behind one button. */
  list(body: string, buttonLabel: string, rows: ListRow[]): OutboundMessage {
    return {
      type: "interactive",
      interactive: {
        type: "list",
        body: { text: body },
        action: { button: buttonLabel, sections: [{ title: buttonLabel, rows }] },
      },
    };
  },

  /** Opens a published Flow; "data_exchange" makes WhatsApp call our endpoint with INIT. */
  flow(body: string, flowId: string, flowToken: string, cta: string): OutboundMessage {
    return {
      type: "interactive",
      interactive: {
        type: "flow",
        body: { text: body },
        action: {
          name: "flow",
          parameters: {
            flow_message_version: "3",
            flow_id: flowId,
            flow_token: flowToken,
            flow_cta: cta,
            flow_action: "data_exchange",
          },
        },
      },
    };
  },

  /** Approved template with body parameters and optional quick-reply payloads (in button order). */
  template(name: string, language: string, bodyParams: string[], quickReplyPayloads: string[] = []): OutboundMessage {
    const components: Record<string, unknown>[] = [];
    if (bodyParams.length) {
      components.push({ type: "body", parameters: bodyParams.map((text) => ({ type: "text", text })) });
    }
    quickReplyPayloads.forEach((payload, index) => {
      components.push({
        type: "button", sub_type: "quick_reply", index: String(index),
        parameters: [{ type: "payload", payload }],
      });
    });
    return { type: "template", template: { name, language: { code: language }, components } };
  },
};

// ---------------------------------------------------------------- sending
export type SendResult =
  | { ok: true; wamid: string }
  /** definite = Meta answered with an error, so the message was NOT accepted and may be retried. */
  | { ok: false; definite: boolean; error: string };

export interface WhatsAppSender {
  send(phoneNumberId: string, to: string, message: OutboundMessage): Promise<SendResult>;
}

export class CloudApiSender implements WhatsAppSender {
  constructor(
    private token = env(SECRETS.waAccessToken),
    private version = env(SECRETS.waGraphVersion),
    private timeoutMs = 15_000,
  ) {}

  async send(phoneNumberId: string, to: string, message: OutboundMessage): Promise<SendResult> {
    const url = `https://graph.facebook.com/${this.version}/${phoneNumberId}/messages`;
    let response: Response;
    try {
      response = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", to, ...message }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      // Timeout / network: Meta may or may not have accepted it.
      return { ok: false, definite: false, error: String(error) };
    }

    const json = await response.json().catch(() => ({}));
    const wamid = json?.messages?.[0]?.id;
    if (response.ok && wamid) return { ok: true, wamid };

    const err = json?.error;
    return {
      ok: false,
      definite: response.status < 500,
      error: err ? `${err.code ?? response.status} ${err.message ?? ""}`.trim() : `HTTP ${response.status}`,
    };
  }
}

/** Test double: records every message and returns fake ids. */
export class FakeSender implements WhatsAppSender {
  sent: { phoneNumberId: string; to: string; message: OutboundMessage }[] = [];
  failNext: SendResult | null = null;

  send(phoneNumberId: string, to: string, message: OutboundMessage): Promise<SendResult> {
    if (this.failNext) {
      const result = this.failNext;
      this.failNext = null;
      return Promise.resolve(result);
    }
    this.sent.push({ phoneNumberId, to, message });
    return Promise.resolve({ ok: true, wamid: `wamid.fake.${this.sent.length}` });
  }
}
