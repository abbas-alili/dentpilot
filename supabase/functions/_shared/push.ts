// Web Push (VAPID) to staff devices. An interface so tests use a fake.

import webpush from "npm:web-push@3.6.7";
import { env, SECRETS } from "./config.ts";

export interface PushSubscription {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** gone = the browser unsubscribed (404/410): stop using this endpoint. */
export type PushResult = { ok: true } | { ok: false; gone: boolean; error: string };

export interface PushSender {
  send(subscription: PushSubscription, payload: Record<string, unknown>): Promise<PushResult>;
}

export class WebPushSender implements PushSender {
  constructor() {
    webpush.setVapidDetails(env(SECRETS.vapidSubject), env(SECRETS.vapidPublic), env(SECRETS.vapidPrivate));
  }

  async send(sub: PushSubscription, payload: Record<string, unknown>): Promise<PushResult> {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        JSON.stringify(payload),
        { TTL: 3600, urgency: payload.kind === "escalation" ? "high" : "normal" },
      );
      return { ok: true };
    } catch (error) {
      const status = (error as { statusCode?: number }).statusCode ?? 0;
      return { ok: false, gone: status === 404 || status === 410, error: `${status} ${String(error)}` };
    }
  }
}

export class FakePushSender implements PushSender {
  sent: { endpoint: string; payload: Record<string, unknown> }[] = [];
  respond: PushResult = { ok: true };
  send(sub: PushSubscription, payload: Record<string, unknown>): Promise<PushResult> {
    this.sent.push({ endpoint: sub.endpoint, payload });
    return Promise.resolve(this.respond);
  }
}
