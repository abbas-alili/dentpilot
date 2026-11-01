// End-to-end tests: real handlers + real database (as dentpilot_agent);
// WhatsApp and web push are replaced by recorders. Run via scripts/test_edge.sh.
//
// Env: TEST_AGENT_DB_URL (dentpilot_agent), TEST_ADMIN_DB_URL (superuser, for fixtures/asserts)

import postgres from "npm:postgres@3.4.5";
import { assert, assertEquals } from "./assert.ts";
import { decryptAsMeta, encryptAsMeta, generateFlowKeys, signedRequest } from "./helpers.ts";
import { setDb } from "../_shared/db.ts";
import { importFlowPrivateKey, toHex } from "../_shared/crypto.ts";
import { FakePushSender } from "../_shared/push.ts";
import { FakeSender, type OutboundMessage } from "../_shared/whatsapp.ts";
import { createWebhookHandler } from "../whatsapp-webhook/handler.ts";
import { createFlowHandler } from "../flow-endpoint/handler.ts";
import { createJobsHandler, runJobs } from "../run-jobs/handler.ts";
import { createFeedHandler } from "../calendar-feed/handler.ts";
import { FakeRouter, type RouterDecision } from "../_shared/router.ts";
import { GoogleCalendarClient } from "../_shared/gcal.ts";
import { createOAuthHandler } from "../google-oauth/handler.ts";
import { FakeGoogle } from "./fake_google.ts";

const SECRET = "test-app-secret";
const PATIENT = "994551234567";
const CLINIC = "00000000-0000-0000-0000-00000000000a";
const DR_ONE = "00000000-0000-0000-0000-0000000000d1";
const STAFF = "aaaaaaaa-0000-0000-0000-0000000000e1";

Deno.test({
  name: "a patient's journey through every Edge Function",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    const agent = postgres(Deno.env.get("TEST_AGENT_DB_URL")!, { prepare: false, max: 3, onnotice: () => {} });
    const admin = postgres(Deno.env.get("TEST_ADMIN_DB_URL")!, { max: 1, onnotice: () => {} });
    setDb(agent);

    // ---------------------------------------------------------------- fixtures
    // The first part of the journey runs live (no shadow mode, no clinic-wide approval,
    // "any dentist" offered); the clinic's real settings are switched on further down.
    await admin`update core.clinics set wa_phone_number_id = 'PN_TEST', shadow_mode = false,
                       all_bookings_need_approval = false, offer_any_dentist = true where id = ${CLINIC}`;
    await admin`insert into auth.users (id) values (${STAFF})`;
    await admin`insert into ops.staff (user_id, clinic_id, role) values (${STAFF}, ${CLINIC}, 'receptionist')`;
    await admin`insert into ops.push_subscriptions (user_id, endpoint, p256dh, auth)
                values (${STAFF}, 'https://push.example/staff1', 'k', 'a')`;
    await admin`update core.kb_entries set approved_by = ${STAFF}, approved_at = now()
                 where clinic_id = ${CLINIC} and topic = 'hours' and language = 'az'`;

    const sender = new FakeSender();
    const push = new FakePushSender();
    const pending: Promise<unknown>[] = [];
    const flowIds = { az: "FLOW_AZ", ru: "FLOW_RU" };
    const webhookDeps: Parameters<typeof createWebhookHandler>[0] = {
      appSecret: SECRET, verifyToken: "verify-me", sender, flowIds, background: (p) => pending.push(p),
    };
    const webhook = createWebhookHandler(webhookDeps);
    const keys = await generateFlowKeys();
    const flow = createFlowHandler({ privateKey: await importFlowPrivateKey(keys.privatePem), appSecret: SECRET, verifySignature: true });
    const google = new FakeGoogle();
    const jobsDeps = {
      cronSecret: "cron", sender, push, flowIds, budgetMs: 5_000,
      google: new GoogleCalendarClient("client-id", "client-secret", google.fetch),
    };

    let seq = 0;
    /** Deliver one inbound WhatsApp message and wait for the background processing. */
    async function receive(message: Record<string, unknown>, id = `wamid.in.${++seq}`): Promise<Response> {
      const payload = { entry: [{ changes: [{ field: "messages", value: {
        metadata: { phone_number_id: "PN_TEST" },
        contacts: [{ wa_id: message.from ?? PATIENT, profile: { name: "Leyla" } }],
        messages: [{ from: PATIENT, id, timestamp: String(Math.floor(Date.now() / 1000)), ...message }],
      } }] }] };
      const response = await webhook(await signedRequest("https://x/whatsapp-webhook", payload, SECRET));
      await Promise.all(pending.splice(0));
      return response;
    }
    const text = (body: string) => ({ type: "text", text: { body } });
    const tap = (id: string) => ({ type: "interactive", interactive: { type: "list_reply", list_reply: { id, title: id } } });
    const button = (id: string) => ({ type: "interactive", interactive: { type: "button_reply", button_reply: { id, title: id } } });
    const last = (): OutboundMessage => sender.sent.at(-1)!.message;
    const lastText = (): string => (last() as { text: { body: string } }).text.body;

    async function flowCall(payload: Record<string, unknown>): Promise<{ status: number; body: any }> {
      const { request, aesKey, iv } = await encryptAsMeta(payload, keys.publicKey);
      const response = await flow(await signedRequest("https://x/flow-endpoint", request, SECRET));
      const raw = await response.text();
      return { status: response.status, body: response.status === 200 ? await decryptAsMeta(raw, aesKey, iv) : raw };
    }

    // ---------------------------------------------------------------- webhook basics
    await t.step("webhook handshake and signature check", async () => {
      const ok = await webhook(new Request("https://x/?hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=42"));
      assertEquals(await ok.text(), "42");
      assertEquals((await webhook(new Request("https://x/?hub.mode=subscribe&hub.verify_token=wrong"))).status, 403);
      const forged = new Request("https://x/", { method: "POST", body: "{}", headers: { "x-hub-signature-256": "sha256=00" } });
      assertEquals((await webhook(forged)).status, 401);
    });

    await t.step("first message gets the menu; a redelivered webhook gets nothing more", async () => {
      assertEquals((await receive(text("Salam"), "wamid.hello")).status, 200);
      assertEquals(sender.sent.length, 1);
      assertEquals(sender.sent[0].to, PATIENT);
      assertEquals(sender.sent[0].phoneNumberId, "PN_TEST");
      assertEquals((last() as any).interactive.type, "list");
      await receive(text("Salam"), "wamid.hello");
      assertEquals(sender.sent.length, 1, "duplicate delivery is not answered twice");
    });

    await t.step("hours come from the approved knowledge base", async () => {
      await receive(tap("menu:hours"));
      assertEquals(lastText(), "Bazar ertəsi – Şənbə, 10:00–19:00.");
    });

    // ---------------------------------------------------------------- booking via Flow
    let appointmentId = "";
    await t.step("book through the Flow: menu → INIT → dates → slots → hold → completion", async () => {
      await receive(tap("menu:book"));
      const params = (last() as any).interactive.action.parameters;
      assertEquals(params.flow_id, "FLOW_AZ");
      const token: string = params.flow_token;

      assertEquals((await flowCall({ action: "ping", version: "3.0" })).body, { data: { status: "active" } });

      const init = await flowCall({ action: "INIT", version: "3.0", flow_token: token });
      assertEquals(init.body.screen, "SCREEN_SERVICE");
      assertEquals(init.body.data.services.map((s: any) => s.id), ["svc_exam", "svc_clean", "svc_fill"]);
      assertEquals(init.body.data.dentists[0], { id: "any", title: "Fərqi yoxdur" });

      const dates = await flowCall({ action: "data_exchange", version: "3.0", flow_token: token,
        data: { step: "dates", service: "svc_exam", dentist: "any" } });
      assertEquals(dates.body.screen, "SCREEN_SLOT");
      assert(dates.body.data.dates.length > 0, "there are free dates");
      const date = dates.body.data.dates.at(-1).id;   // furthest date: safely outside the 4-h cutoff

      const slots = await flowCall({ action: "data_exchange", version: "3.0", flow_token: token,
        data: { step: "slots", service: "svc_exam", dentist: "any", date } });
      assertEquals(slots.body.data.slots_visible, true);
      assertEquals(slots.body.data.dates.length, dates.body.data.dates.length, "dates are resent with slots");
      const slot = slots.body.data.slots[0].id;
      assertEquals(slots.body.data.slots[0].title, "10:00");

      const hold = await flowCall({ action: "data_exchange", version: "3.0", flow_token: token,
        data: { step: "hold", service: "svc_exam", dentist: DR_ONE, date, slot: [slot] } });
      assertEquals(hold.body.screen, "SCREEN_CONFIRM");
      assert(hold.body.data.summary.includes("Müayinə · 30 dəq"), hold.body.data.summary);
      assertEquals(hold.body.data.patient_name, "Leyla");

      await receive({ type: "interactive", interactive: { type: "nfm_reply", nfm_reply: {
        response_json: JSON.stringify({ hold_id: hold.body.data.hold_id, name: "Leyla Məmmədova", flow_token: token }),
      } } }, "wamid.flowdone");
      assert(lastText().startsWith("Randevunuz təsdiqləndi ✅\nMüayinə\n"), lastText());

      const [appt] = await admin`select a.id, a.status from core.appointments a
                                  join core.patients p on p.id = a.patient_id where p.wa_id = ${PATIENT}`;
      assertEquals(appt.status, "booked");
      appointmentId = appt.id;
      const [p] = await admin`select display_name from core.patients where wa_id = ${PATIENT}`;
      assertEquals(p.display_name, "Leyla Məmmədova");
    });

    await t.step("Flow endpoint error codes: bad token 427, undecryptable 421, unsigned 432", async () => {
      assertEquals((await flowCall({ action: "INIT", version: "3.0", flow_token: "nope" })).status, 427);
      const garbage = await flow(await signedRequest("https://x/", { encrypted_flow_data: "AA==", encrypted_aes_key: "AA==", initial_vector: "AA==" }, SECRET));
      assertEquals(garbage.status, 421);
      assertEquals((await flow(new Request("https://x/", { method: "POST", body: "{}" }))).status, 432);
    });

    // ---------------------------------------------------------------- reminder → confirm attendance
    await t.step("reminder job sends the template with confirm/cancel buttons; tapping confirm works", async () => {
      await admin`select ops.enqueue_job('send_reminder', ${CLINIC},
                    ${admin.json({ appointment_id: appointmentId, offset_minutes: 1440 })}, 'test:reminder')`;
      const before = sender.sent.length;
      await runJobs(jobsDeps);
      const sent = sender.sent.slice(before).map((s) => s.message as any).find((m) => m.type === "template");
      assertEquals(sent?.template.name, "dentpilot_reminder");
      assertEquals(sent?.template.language.code, "az");
      assertEquals(sent?.template.components.length, 3, "body + two quick replies");

      await receive({ type: "button", button: { payload: `remind:confirm:${appointmentId}`, text: "Gələcəyəm" } });
      assertEquals(lastText(), "Təşəkkür edirik, sizi gözləyirik!");
      const [a] = await admin`select status from core.appointments where id = ${appointmentId}`;
      assertEquals(a.status, "confirmed");
    });

    // ---------------------------------------------------------------- cancel
    await t.step("cancel from the menu with a confirmation button", async () => {
      await receive(tap("menu:cancel"));
      const yes = (last() as any).interactive.action.buttons[0].reply.id as string;
      assert(yes.startsWith(`cancel:yes:${appointmentId}:`), yes);
      await receive(button(yes));
      assertEquals(lastText(), "Randevunuz ləğv edildi.");
      const [a] = await admin`select status from core.appointments where id = ${appointmentId}`;
      assertEquals(a.status, "cancelled");
    });

    // ---------------------------------------------------------------- emergency
    await t.step("emergency: safety reply, conversation escalated, staff pushed, bot then silent", async () => {
      await receive(text("Dişim çox ağrıyır, dözə bilmirəm"));
      assert(lastText().includes("103"), lastText());
      const [c] = await admin`select cv.status, cv.status_reason from core.conversations cv
                               join core.patients p on p.id = cv.patient_id
                              where p.wa_id = ${PATIENT} and cv.status <> 'closed'`;
      assertEquals([c.status, c.status_reason], ["escalated", "emergency:pain"]);

      await runJobs(jobsDeps);
      assertEquals(push.sent.at(-1)?.payload.kind, "escalation");
      assertEquals(push.sent.at(-1)?.endpoint, "https://push.example/staff1");

      const before = sender.sent.length;
      await receive(text("Salam?"));
      assertEquals(sender.sent.length, before, "a human is handling it now");
    });

    // ---------------------------------------------------------------- reconciler path
    await t.step("a message that was never processed is picked up by the reconciler", async () => {
      await agent.begin(async (tx) => {
        await tx`select set_config('app.clinic_id', ${CLINIC}, true)`;
        await tx`select core.record_inbound_message('wamid.lost', '994559999999', 'text', 'Salam')`;
      });
      await admin`update core.messages set created_at = now() - interval '5 minutes' where wa_message_id = 'wamid.lost'`;
      const [q] = await admin`select ops.enqueue_stale_messages() as n`;
      assertEquals(q.n, 1);
      await runJobs(jobsDeps);
      assertEquals(sender.sent.at(-1)?.to, "994559999999");
      const [m] = await admin`select processed_at from core.messages where wa_message_id = 'wamid.lost'`;
      assert(m.processed_at, "marked processed");
    });

    // ---------------------------------------------------------------- run-jobs auth, calendar feed
    await t.step("run-jobs rejects calls without the cron secret", async () => {
      const handler = createJobsHandler(jobsDeps);
      assertEquals((await handler(new Request("https://x/", { method: "POST" }))).status, 401);
      assertEquals((await handler(new Request("https://x/", { method: "POST", headers: { authorization: "Bearer cron" } }))).status, 200);
    });

    await t.step("calendar feed shows the dentist's bookings; unknown tokens get an empty calendar", async () => {
      await admin`insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until)
                  select ${CLINIC}, p.id, ${DR_ONE}, '00000000-0000-0000-0000-0000000000e1',
                         now() + interval '3 days', now() + interval '3 days 30 minutes', now() + interval '3 days 30 minutes'
                    from core.patients p where p.wa_id = ${PATIENT}`;
      const token = toHex(crypto.getRandomValues(new Uint8Array(32)));
      await admin`insert into ops.calendar_feeds (clinic_id, professional_id, token_sha256)
                  values (${CLINIC}, ${DR_ONE}, ops.sha256_hex(${token}))`;
      const feed = createFeedHandler();
      const ics = await (await feed(new Request(`https://x/calendar-feed/${token}.ics`))).text();
      assert(ics.includes("SUMMARY:Leyla — Müayinə"), ics);
      assertEquals((ics.match(/BEGIN:VEVENT/g) ?? []).length, 1, "the cancelled booking is not shown");
      const empty = await (await feed(new Request(`https://x/calendar-feed/${"0".repeat(64)}.ics`))).text();
      assert(!empty.includes("VEVENT") && empty.includes("BEGIN:VCALENDAR"));
    });

    // ---------------------------------------------------------------- E2: LLM router
    const queue: (RouterDecision | null)[] = [];
    const router = new FakeRouter(() => queue.shift() ?? null);
    webhookDeps.router = router;
    const decide = (intent: RouterDecision["intent"], confidence = 0.9, kbEntryId: string | null = null): RouterDecision =>
      ({ intent, kbEntryId, language: "az", confidence });
    const P2 = "994557777771";
    const P3 = "994557777772";
    const from = (wa: string, body: string) => ({ from: wa, type: "text", text: { body } });

    await t.step("router: 'is there a slot tomorrow at 3?' opens the booking Flow", async () => {
      queue.push(decide("book"));
      await receive(from(P2, "Sabah saat 3-ə yer var?"));
      assertEquals(router.calls.length, 1);
      const call = router.calls[0];
      assertEquals(call.message, "Sabah saat 3-ə yer var?");
      assert(call.faq.some((f) => f.topic === "hours"), "approved FAQ entries are offered to the router");
      assertEquals(call.services.map((s) => s.code), ["svc_exam", "svc_clean", "svc_fill"]);
      assertEquals(sender.sent.at(-1)?.to, P2);
      assertEquals((last() as any).interactive.type, "flow");
    });

    await t.step("router: FAQ question gets the approved answer word for word", async () => {
      const [hours] = await admin`select id::text from core.kb_entries where topic = 'hours' and language = 'az'`;
      queue.push(decide("faq", 0.95, hours.id));
      await receive(from(P2, "neçədə açılırsız?"));
      assertEquals(lastText(), "Bazar ertəsi – Şənbə, 10:00–19:00.");
      assert(router.calls.at(-1)!.recentTurns.length > 0, "recent conversation is passed as context");
    });

    await t.step("router: a clinical question goes to a dentist, then the bot stays silent", async () => {
      queue.push(decide("clinical_question"));
      await receive(from(P2, "Plombdan sonra nə vaxt yemək olar?"));
      assertEquals(lastText(), "Bu sualı həkimə ötürdük, sizə cavab yazacaq.");
      const [c] = await admin`select cv.status, cv.status_reason from core.conversations cv
                               join core.patients p on p.id = cv.patient_id where p.wa_id = ${P2} and cv.status <> 'closed'`;
      assertEquals([c.status, c.status_reason], ["handed_to_staff", "clinical_question"]);
      const calls = router.calls.length;
      await receive(from(P2, "Bəs isti çay?"));
      assertEquals(router.calls.length, calls, "router not called while staff handle it");
    });

    await t.step("router unsure, router down, or 'other' → the menu; thanks → a short reply", async () => {
      queue.push(decide("book", 0.3));
      await receive(from(P3, "hmm"));
      assertEquals((last() as any).interactive.type, "list", "low confidence → menu");
      queue.push(null);
      await receive(from(P3, "???"));
      assertEquals((last() as any).interactive.type, "list", "router failure → menu");
      queue.push(decide("thanks"));
      await receive(from(P3, "çox sağ olun"));
      assertEquals(lastText(), "Buyurun! Başqa sualınız olsa, yazın.");
    });

    await t.step("emergencies never reach the router", async () => {
      const calls = router.calls.length;
      await receive(from(P3, "dişim sındı, qan gəlir"));
      assertEquals(router.calls.length, calls);
      assert(lastText().includes("103"));
    });

    // ---------------------------------------------------------------- shadow mode (clinic answers)
    await admin`update core.clinics set shadow_mode = true, all_bookings_need_approval = true,
                       offer_any_dentist = false where id = ${CLINIC}`;
    const P4 = "994557777774";

    /** Run SQL as a signed-in staff member (Supabase Auth → role authenticated). */
    async function asStaff<T>(fn: (tx: any) => Promise<T>): Promise<T> {
      return await admin.begin(async (tx) => {
        await tx`select set_config('request.jwt.claim.sub', ${STAFF}, true)`;
        await tx`set local role authenticated`;
        return await fn(tx);
      }) as T;
    }

    await t.step("shadow mode: the bot's reply waits as a draft; staff are told", async () => {
      const before = sender.sent.length;
      await receive(from(P4, "Salam"));
      assertEquals(sender.sent.length, before, "nothing reaches the patient yet");
      const drafts = await admin`select m.id, m.kind from core.messages m join core.patients p on p.id = m.patient_id
                                  where p.wa_id = ${P4} and m.delivery_status = 'draft'`;
      assertEquals(drafts.length, 1);
      assertEquals(drafts[0].kind, "interactive");
      const [n] = await admin`select count(*)::int as n from ops.staff_notifications where kind = 'draft_waiting'`;
      assert(n.n >= 1, "draft_waiting notification");
    });

    await t.step("shadow mode: the doctor approves, run-jobs sends exactly that message", async () => {
      const [draft] = await admin`select m.id from core.messages m join core.patients p on p.id = m.patient_id
                                   where p.wa_id = ${P4} and m.delivery_status = 'draft'`;
      const [ok] = await asStaff<any[]>((tx) => tx`select core.approve_draft(${draft.id}) as ok`);
      assert(ok.ok);
      await runJobs(jobsDeps);
      assertEquals(sender.sent.at(-1)?.to, P4);
      assertEquals((last() as any).interactive.type, "list");
      const [m] = await admin`select delivery_status, wa_message_id from core.messages where id = ${draft.id}`;
      assertEquals(m.delivery_status, "sent");
    });

    await t.step("specific doctor only: the Flow offers no 'any dentist' option", async () => {
      const token = await agent.begin(async (tx) => {
        await tx`select set_config('app.clinic_id', ${CLINIC}, true)`;
        const [p] = await tx`select id from core.patients where wa_id = ${P4}`;
        const [r] = await tx`select core.issue_flow_token(${p.id}, 'az') as token`;
        return r.token as string;
      });
      const init = await flowCall({ action: "INIT", version: "3.0", flow_token: token });
      assert(!init.body.data.dentists.some((d: any) => d.id === "any"));
      assertEquals(init.body.data.dentists.length, 2);
    });

    await t.step("shadow mode: the emergency reply is the one message sent at once", async () => {
      const P5 = "994557777775";
      const before = sender.sent.length;
      await receive(from(P5, "Dişim çox ağrıyır, şişib"));
      assertEquals(sender.sent.length, before + 1, "sent immediately, no approval needed");
      assertEquals(sender.sent.at(-1)?.to, P5);
      assert(lastText().includes("103-ə zəng edin"), lastText());
      const [drafts] = await admin`select count(*)::int as n from core.messages m join core.patients p on p.id = m.patient_id
                                    where p.wa_id = ${P5} and m.delivery_status = 'draft'`;
      assertEquals(drafts.n, 0, "nothing else was produced for this message");
    });

    // ---------------------------------------------------------------- Google Calendar
    const ADMIN = "aaaaaaaa-0000-0000-0000-0000000000a1";
    await admin`insert into auth.users (id) values (${ADMIN})`;
    await admin`insert into ops.staff (user_id, clinic_id, role) values (${ADMIN}, ${CLINIC}, 'admin')`;

    await t.step("connect Google Calendar: admin starts OAuth, Google calls back, link saved", async () => {
      const oauth = createOAuthHandler({
        google: new GoogleCalendarClient("client-id", "client-secret", google.fetch),
        clientId: "client-id", redirectUri: "https://x/functions/v1/google-oauth/callback",
        stateSecret: "state-secret", staffAppUrl: "https://staff.example",
        verifyUser: (jwt) => Promise.resolve(jwt === "admin-jwt" ? ADMIN : jwt === "recept-jwt" ? STAFF : null),
      });
      const startAs = (jwt: string) => oauth(new Request("https://x/google-oauth/start", {
        method: "POST", headers: { authorization: `Bearer ${jwt}` }, body: JSON.stringify({ professional_id: DR_ONE }),
      }));
      assertEquals((await startAs("nobody")).status, 401);
      assertEquals((await startAs("recept-jwt")).status, 403, "a receptionist may not connect a dentist's calendar");

      const { url } = await (await startAs("admin-jwt")).json();
      const consent = new URL(url);
      assertEquals(consent.searchParams.get("access_type"), "offline");
      assert(consent.searchParams.get("scope")!.includes("calendar.events"));

      const tampered = await oauth(new Request(`https://x/google-oauth/callback?code=c&state=${consent.searchParams.get("state")}x`));
      assertEquals(tampered.headers.get("location"), "https://staff.example/settings/calendar?status=invalid");

      const done = await oauth(new Request(`https://x/google-oauth/callback?code=c&state=${consent.searchParams.get("state")}`));
      assertEquals(done.headers.get("location"), "https://staff.example/settings/calendar?status=connected");
      const [link] = await admin`select google_email, status, calendar_id from ops.google_calendar_links where professional_id = ${DR_ONE}`;
      assertEquals([link.google_email, link.status, link.calendar_id], ["ayten@gmail.example", "active", "primary"]);
    });

    let gAppt = "";
    await t.step("Google Calendar: booking appears, moves, and disappears when cancelled", async () => {
      const [a] = await admin`insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until)
                              select ${CLINIC}, p.id, ${DR_ONE}, '00000000-0000-0000-0000-0000000000e1',
                                     now() + interval '5 days', now() + interval '5 days 30 minutes', now() + interval '5 days 30 minutes'
                                from core.patients p where p.wa_id = ${PATIENT} returning id`;
      gAppt = a.id;
      await runJobs(jobsDeps);
      const id = "dp" + gAppt.replace(/-/g, "");
      assertEquals(google.events.get(id)?.summary, "Leyla — Müayinə");
      assertEquals(google.events.get(id)?.status, "confirmed");

      await admin`update core.appointments set start_at = start_at + interval '1 hour', end_at = end_at + interval '1 hour',
                                               blocked_until = blocked_until + interval '1 hour' where id = ${gAppt}`;
      await runJobs(jobsDeps);
      assertEquals(google.events.size, 1, "moved, not duplicated");
      const [s] = await admin`select start_at from core.appointments where id = ${gAppt}`;
      assertEquals(google.events.get(id).start.dateTime, s.start_at.toISOString());

      await admin`update core.appointments set status = 'cancelled' where id = ${gAppt}`;
      await runJobs(jobsDeps);
      assert(!google.events.has(id), "cancelled → removed from her calendar");
    });

    await t.step("Google Calendar: revoked access stops syncing and alerts staff", async () => {
      google.revokedRefreshTokens.add("refresh-from-code");
      await admin`insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until)
                  select ${CLINIC}, p.id, ${DR_ONE}, '00000000-0000-0000-0000-0000000000e1',
                         now() + interval '6 days', now() + interval '6 days 30 minutes', now() + interval '6 days 30 minutes'
                    from core.patients p where p.wa_id = ${PATIENT}`;
      const summary = await runJobs(jobsDeps);
      assertEquals(summary.failed, 0, "the job completes; it does not retry forever");
      const [link] = await admin`select status from ops.google_calendar_links where professional_id = ${DR_ONE}`;
      assertEquals(link.status, "needs_reconnect");
      const [n] = await admin`select count(*)::int as n from ops.staff_notifications where kind = 'calendar_disconnected'`;
      assert(n.n >= 1);
    });

    await agent.end();
    await admin.end();
  },
});
