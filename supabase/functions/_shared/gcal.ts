// Google Calendar API v3 — the few calls DentPilot needs:
//   refresh an access token, upsert an event by our own id, delete an event.
// fetch is injectable so tests run against a fake Google.
//
// Event id = "dp" + appointment uuid without dashes: only a–v and 0–9, which
// Google accepts as a client-chosen id. Upsert = PUT (update); on 404, POST
// (insert with that id). PUT also revives an event someone deleted by hand.

import { env } from "./config.ts";

export class GoogleAuthRevoked extends Error {}

export interface CalendarEvent {
  appointmentId: string;
  summary: string;
  startsAt: Date;
  endsAt: Date;
  tentative: boolean;
  timezone: string;
}

type Fetch = typeof fetch;

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const API = "https://www.googleapis.com/calendar/v3";

export function eventIdFor(appointmentId: string): string {
  return "dp" + appointmentId.replace(/-/g, "").toLowerCase();
}

export class GoogleCalendarClient {
  constructor(
    private clientId = env("GOOGLE_CLIENT_ID"),
    private clientSecret = env("GOOGLE_CLIENT_SECRET"),
    private fetchFn: Fetch = fetch,
    private timeoutMs = 10_000,
  ) {}

  /** Access token from a refresh token. Throws GoogleAuthRevoked if Google says invalid_grant. */
  async accessToken(refreshToken: string): Promise<string> {
    const response = await this.fetchFn(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token", refresh_token: refreshToken,
        client_id: this.clientId, client_secret: this.clientSecret,
      }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const json = await response.json().catch(() => ({}));
    if (response.ok && json.access_token) return json.access_token;
    if (json.error === "invalid_grant") throw new GoogleAuthRevoked(json.error_description ?? "invalid_grant");
    throw new Error(`google token refresh failed: HTTP ${response.status} ${json.error ?? ""}`);
  }

  /** Exchange an OAuth authorization code (google-oauth callback). */
  async exchangeCode(code: string, redirectUri: string): Promise<{ refreshToken: string; email: string | null }> {
    const response = await this.fetchFn(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code", code, redirect_uri: redirectUri,
        client_id: this.clientId, client_secret: this.clientSecret,
      }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const json = await response.json().catch(() => ({}));
    if (!response.ok || !json.refresh_token) {
      throw new Error(`google code exchange failed: HTTP ${response.status} ${json.error ?? "no refresh_token"}`);
    }
    // The id_token comes straight from Google over TLS; we only read the email claim.
    let email: string | null = null;
    try {
      const claims = JSON.parse(atob(String(json.id_token).split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
      email = claims.email ?? null;
    } catch { /* email is informational only */ }
    return { refreshToken: json.refresh_token, email };
  }

  async upsertEvent(accessToken: string, calendarId: string, event: CalendarEvent): Promise<string> {
    const id = eventIdFor(event.appointmentId);
    const body = {
      id,
      summary: event.summary,
      description: "DentPilot",
      start: { dateTime: event.startsAt.toISOString(), timeZone: event.timezone },
      end: { dateTime: event.endsAt.toISOString(), timeZone: event.timezone },
      status: event.tentative ? "tentative" : "confirmed",
      extendedProperties: { private: { dentpilot_appointment: event.appointmentId } },
    };
    const base = `${API}/calendars/${encodeURIComponent(calendarId)}/events`;

    const put = await this.call(accessToken, "PUT", `${base}/${id}`, body);
    if (put.status === 404) {
      const post = await this.call(accessToken, "POST", base, body);
      await this.ensureOk(post, "insert event");
    } else {
      await this.ensureOk(put, "update event");
    }
    return id;
  }

  async deleteEvent(accessToken: string, calendarId: string, eventId: string): Promise<void> {
    const response = await this.call(
      accessToken, "DELETE", `${API}/calendars/${encodeURIComponent(calendarId)}/events/${eventId}`,
    );
    if ([404, 410].includes(response.status)) return;   // already gone
    await this.ensureOk(response, "delete event");
  }

  private async call(token: string, method: string, url: string, body?: unknown): Promise<Response> {
    return await this.fetchFn(url, {
      method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
  }

  private async ensureOk(response: Response, what: string): Promise<void> {
    if (response.ok) {
      await response.body?.cancel();
      return;
    }
    const text = await response.text().catch(() => "");
    // A 401 here is retried (fresh token next run); only invalid_grant on refresh means revoked.
    throw new Error(`google ${what} failed: HTTP ${response.status} ${text.slice(0, 200)}`);
  }
}
