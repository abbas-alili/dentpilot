// Google Calendar client and OAuth state — no network (fake Google).
import { assert, assertEquals, assertRejects } from "./assert.ts";
import { eventIdFor, GoogleAuthRevoked, GoogleCalendarClient } from "../_shared/gcal.ts";
import { signState, verifyState } from "../google-oauth/handler.ts";
import { FakeGoogle } from "./fake_google.ts";

const APPT = "8a8c4da8-2a7f-4bf3-a103-8498fd61c6f1";
const event = {
  appointmentId: APPT, summary: "Leyla — Plomb", startsAt: new Date("2026-11-03T06:00:00Z"),
  endsAt: new Date("2026-11-03T06:45:00Z"), tentative: true, timezone: "Asia/Baku",
};

Deno.test("event ids use only characters Google accepts (a–v, 0–9)", () => {
  assert(/^[a-v0-9]{5,1024}$/.test(eventIdFor(APPT)));
});

Deno.test("upsert inserts once, then updates the same event; delete is idempotent", async () => {
  const google = new FakeGoogle();
  const client = new GoogleCalendarClient("id", "secret", google.fetch);
  const token = await client.accessToken("refresh");

  const id = await client.upsertEvent(token, "primary", event);
  assertEquals(google.calls.slice(-2), ["PUT /calendar/v3/calendars/primary/events/" + id, "POST /calendar/v3/calendars/primary/events"]);
  assertEquals(google.events.get(id).status, "tentative");
  assertEquals(google.events.get(id).start, { dateTime: "2026-11-03T06:00:00.000Z", timeZone: "Asia/Baku" });

  await client.upsertEvent(token, "primary", { ...event, tentative: false });
  assertEquals(google.events.size, 1, "no duplicate event");
  assertEquals(google.events.get(id).status, "confirmed");

  await client.deleteEvent(token, "primary", id);
  await client.deleteEvent(token, "primary", id);   // already gone: fine
  assertEquals(google.events.size, 0);
});

Deno.test("a revoked refresh token is reported as GoogleAuthRevoked", async () => {
  const google = new FakeGoogle();
  google.revokedRefreshTokens.add("old");
  await assertRejects(() => new GoogleCalendarClient("id", "s", google.fetch).accessToken("old"), GoogleAuthRevoked, "revoked");
});

Deno.test("OAuth state: round trip; tampered or expired state is rejected", async () => {
  const state = await signState("k", { p: "prof", u: "user", exp: Date.now() + 60_000 });
  assertEquals((await verifyState("k", state))?.p, "prof");
  assertEquals(await verifyState("other-key", state), null);
  assertEquals(await verifyState("k", state.replace(/^./, "x")), null);
  assertEquals(await verifyState("k", await signState("k", { p: "p", u: "u", exp: Date.now() - 1 })), null);
});
