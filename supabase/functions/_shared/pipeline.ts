// The assistant's message pipeline.
//
//   claim ─▶ structured reply? (Flow completion, menu/button tap) ─▶ handle it
//         └▶ free text ─▶ emergency gate ─▶ opt-out words ─▶ language ─▶
//                         hand-over check ─▶ LLM router (E2) ─▶ the same handlers
//                                            no router / unsure / failed ─▶ menu
//         └▶ media ─▶ hand to staff
//
// The router only CHOOSES an action or an approved FAQ entry; every word the
// patient receives is a reviewed template or an approved answer.
//
// Safety order: the emergency gate runs BEFORE the hand-over check, so an
// emergency is escalated even while staff are handling the conversation.
// Structured replies (buttons, Flow) are handled even after hand-over: they
// are the patient acting on something we offered.
//
// Every reply has send key "reply:<inbound id>:<n>", so re-processing the same
// inbound message (retry, reconciler) never sends a reply twice.

import { sqlState, type Tx, withClinic } from "./db.ts";
import { emergencyGate } from "./emergency_gate.ts";
import { detectLanguage, fill, formatDate, formatTime, type Lang } from "./i18n.ts";
import { sendQueued, sendRecorded } from "./outbound.ts";
import { t } from "./texts.ts";
import { type OutboundMessage, wa, type WhatsAppSender } from "./whatsapp.ts";
import { env, SECRETS } from "./config.ts";
import { CONFIDENCE_THRESHOLD, type Router, type RouterInput } from "./router.ts";

export interface PipelineDeps {
  sender: WhatsAppSender;
  /** E2 LLM router; without it, free text gets the menu (E1 behaviour). */
  router?: Router;
  /** Flow id per language; defaults to the WA_FLOW_ID_* secrets. */
  flowIds?: Record<Lang, string>;
}

export type Outcome = "processed" | "skipped";

interface Ctx {
  deps: PipelineDeps;
  clinicId: string;
  messageId: string;
  patientId: string;
  conversationId: string;
  conversationStatus: string;
  lang: Lang;
  kind: string;
  body: string;
  replies: number;
}

const MEDIA_KINDS = new Set(["image", "audio", "video", "document", "sticker"]);
const OPT_OUT_WORDS = new Set(["stop", "dayandır", "dayandir", "стоп"]);
const OPT_IN_WORDS = new Set(["start", "başla", "basla", "старт"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// =============================================================================
// Entry point
// =============================================================================
export async function processInbound(deps: PipelineDeps, clinicId: string, messageId: string): Promise<Outcome> {
  const loaded = await withClinic(clinicId, async (tx) => {
    const [claimed] = await tx`select core.claim_message_for_processing(${messageId}) as ok`;
    if (!claimed.ok) return null;
    const [row] = await tx`
      select m.kind, coalesce(m.body, '') as body, m.patient_id, m.conversation_id,
             p.preferred_language as lang, cv.status as conversation_status
        from core.messages m
        join core.patients p       on p.id  = m.patient_id
        join core.conversations cv on cv.id = m.conversation_id
       where m.id = ${messageId}`;
    return row;
  });
  if (!loaded) return "skipped";   // someone else is processing it, or it's done

  const ctx: Ctx = {
    deps, clinicId, messageId,
    patientId: loaded.patient_id,
    conversationId: loaded.conversation_id,
    conversationStatus: loaded.conversation_status,
    lang: loaded.lang === "ru" ? "ru" : "az",
    kind: loaded.kind,
    body: loaded.body,
    replies: 0,
  };

  try {
    await handle(ctx);
    await withClinic(clinicId, (tx) => tx`select core.mark_message_processed(${messageId})`);
    return "processed";
  } catch (error) {
    await withClinic(clinicId, (tx) => tx`select core.mark_message_attempt_failed(${messageId})`);
    throw error;
  }
}

async function handle(ctx: Ctx): Promise<void> {
  if (ctx.kind === "flow_reply") return await onFlowCompleted(ctx);
  if (ctx.kind === "interactive") return await onAction(ctx, ctx.body);
  if (ctx.kind === "text") return await onText(ctx);
  if (MEDIA_KINDS.has(ctx.kind)) return await onMedia(ctx);
  if (ctx.kind === "reaction") return;                          // nothing to do
  if (await assistantMayReply(ctx)) await sendMenu(ctx);       // location, unsupported, …
}

// =============================================================================
// Free text
// =============================================================================
async function onText(ctx: Ctx): Promise<void> {
  const gate = emergencyGate(ctx.body);
  if (gate.escalate) return await escalate(ctx, `emergency:${gate.category}`);

  const word = ctx.body.trim().toLocaleLowerCase("az");
  if (OPT_OUT_WORDS.has(word) || OPT_IN_WORDS.has(word)) {
    const optOut = OPT_OUT_WORDS.has(word);
    await withClinic(ctx.clinicId, (tx) => tx`select core.set_reminder_opt_out(${ctx.patientId}, ${optOut})`);
    return await reply(ctx, wa.text(t(optOut ? "opted_out" : "opted_in", ctx.lang)));
  }

  const detected = detectLanguage(ctx.body);
  if (detected && detected !== ctx.lang) await setLanguage(ctx, detected);

  if (!(await assistantMayReply(ctx))) return;               // a human is handling it
  await routeFreeText(ctx, detected === null);
}

// =============================================================================
// Free text → router (E2)
// =============================================================================
async function routeFreeText(ctx: Ctx, languageUnknown: boolean): Promise<void> {
  const router = ctx.deps.router;
  if (!router) return await sendMenu(ctx);

  const decision = await router.route(await routerInput(ctx));
  if (!decision || decision.confidence < CONFIDENCE_THRESHOLD) return await sendMenu(ctx);   // decision E2-3

  if (languageUnknown && (decision.language === "az" || decision.language === "ru") && decision.language !== ctx.lang) {
    await setLanguage(ctx, decision.language);
  }

  switch (decision.intent) {
    case "book":
      return await sendFlow(ctx, "book");
    case "reschedule":
      return await startReschedule(ctx);
    case "cancel":
      return await askCancel(ctx, null);
    case "confirm_attendance":
      return await confirmNext(ctx);
    case "faq":
      return await sendFaqEntry(ctx, decision.kbEntryId!);
    case "opt_out":
      await withClinic(ctx.clinicId, (tx) => tx`select core.set_reminder_opt_out(${ctx.patientId}, true)`);
      return await reply(ctx, wa.text(t("opted_out", ctx.lang)));
    case "human_request":
    case "complaint":
      await handOver(ctx, decision.intent);
      return await reply(ctx, wa.text(t("staff_will_reply", ctx.lang)));
    case "clinical_question":
      await handOver(ctx, "clinical_question");
      return await reply(ctx, wa.text(t("clinical_to_staff", ctx.lang)));
    case "thanks":
      return await reply(ctx, wa.text(t("you_are_welcome", ctx.lang)));
    case "greeting":
    case "other":
      return await sendMenu(ctx);
  }
}

async function routerInput(ctx: Ctx): Promise<RouterInput> {
  return await withClinic(ctx.clinicId, async (tx) => {
    const [clinic] = await tx`
      select name, to_char(now() at time zone timezone, 'YYYY-MM-DD') as today
        from core.clinics where id = core.current_clinic_id()`;
    const services = await tx`
      select code, case when ${ctx.lang} = 'ru' then name_ru else name_az end as name
        from core.services where active and bookable_by_patient order by sort_order`;
    const dentists = await tx`select display_name from core.professionals where active order by sort_order`;
    const faq = await tx`select id::text, topic, question, alt_questions from core.kb_for_prompt(${ctx.lang})`;
    const turns = await tx`
      select direction, body from core.messages
       where conversation_id = ${ctx.conversationId} and id <> ${ctx.messageId}
         and body is not null and kind in ('text', 'template')
       order by created_at desc limit 6`;
    return {
      message: ctx.body,
      recentTurns: turns.reverse().map((r) => ({ from: r.direction === "in" ? "patient" : "clinic", text: r.body })),
      todayLocal: clinic.today,
      clinicName: clinic.name,
      services: services.map((r) => ({ code: r.code, name: r.name })),
      dentists: dentists.map((r) => r.display_name),
      faq: faq.map((r) => ({ id: r.id, topic: r.topic, question: r.question, altQuestions: r.alt_questions ?? [] })),
    } as RouterInput;
  });
}

async function sendFaqEntry(ctx: Ctx, entryId: string): Promise<void> {
  const [row] = await withClinic(ctx.clinicId, (tx) =>
    tx`select answer from core.kb_for_prompt(${ctx.lang}) where id = ${entryId}::uuid`
  );
  if (!row) return await sendMenu(ctx);   // entry withdrawn or other language meanwhile
  await reply(ctx, wa.text(row.answer));
}

async function confirmNext(ctx: Ctx): Promise<void> {
  const appointment = await findAppointment(ctx, null);
  if (!appointment) return await reply(ctx, wa.text(t("no_appointment", ctx.lang)));
  await withClinic(ctx.clinicId, (tx) => tx`select core.confirm_attendance(${appointment.id}, ${ctx.patientId})`);
  await reply(ctx, wa.text(t("attendance_confirmed", ctx.lang)));
}

async function onMedia(ctx: Ctx): Promise<void> {
  if (!(await assistantMayReply(ctx))) return;
  await handOver(ctx, "media");
  await reply(ctx, wa.text(t("media_received", ctx.lang)));
}

// =============================================================================
// Structured replies (menu rows, buttons, template quick replies)
//   menu:book | menu:reschedule | menu:cancel | menu:hours | menu:location |
//   menu:staff | menu:lang:az | menu:lang:ru |
//   cancel:yes:<appointment>:<version> | cancel:no |
//   remind:confirm:<appointment> | remind:cancel:<appointment>
// =============================================================================
async function onAction(ctx: Ctx, id: string): Promise<void> {
  const [scope, action, arg1, arg2] = id.split(":");

  if (scope === "menu") {
    switch (action) {
      case "book": return await sendFlow(ctx, "book");
      case "reschedule": return await startReschedule(ctx);
      case "cancel": return await askCancel(ctx, null);
      case "hours": return await sendKnowledge(ctx, "hours");
      case "location": return await sendKnowledge(ctx, "location");
      case "staff":
        await handOver(ctx, "patient_asked");
        return await reply(ctx, wa.text(t("staff_will_reply", ctx.lang)));
      case "lang":
        if (arg1 === "az" || arg1 === "ru") await setLanguage(ctx, arg1);
        return await sendMenu(ctx);
    }
  }

  if (scope === "cancel" && action === "yes" && UUID.test(arg1 ?? "")) {
    return await doCancel(ctx, arg1, Number(arg2));
  }
  if (scope === "cancel" && action === "no") return await reply(ctx, wa.text(t("kept", ctx.lang)));

  if (scope === "remind" && UUID.test(arg1 ?? "")) {
    if (action === "confirm") {
      await withClinic(ctx.clinicId, (tx) => tx`select core.confirm_attendance(${arg1}, ${ctx.patientId})`);
      return await reply(ctx, wa.text(t("attendance_confirmed", ctx.lang)));
    }
    if (action === "cancel") return await askCancel(ctx, arg1);
  }

  await sendMenu(ctx);   // unknown or stale id
}

// =============================================================================
// Booking via Flow
// =============================================================================
async function onFlowCompleted(ctx: Ctx): Promise<void> {
  let response: { hold_id?: string; name?: string; flow_token?: string } = {};
  try {
    response = JSON.parse(ctx.body);
  } catch { /* malformed → treated as expired below */ }

  const holdId = UUID.test(response.hold_id ?? "") ? response.hold_id! : null;
  const result = holdId
    ? await withClinic(ctx.clinicId, async (tx) => {
      const [row] = await tx`select * from core.confirm_hold(${holdId}, ${ctx.patientId}, ${response.name ?? null})`;
      return row ? await appointmentDetails(tx, row.appointment_id) : null;
    })
    : null;

  if (!result) {
    await reply(ctx, wa.text(t("hold_expired", ctx.lang)));
    return await sendFlow(ctx, "book");
  }

  const key = result.status === "pending_approval" ? "booking_pending" : "booking_confirmed";
  await reply(ctx, wa.text(fill(t(key, ctx.lang), placeholders(result, ctx.lang))));
}

async function sendFlow(ctx: Ctx, purpose: "book" | "reschedule", appointment?: AppointmentInfo): Promise<void> {
  const token = await withClinic(ctx.clinicId, async (tx) => {
    const [row] = await tx`select core.issue_flow_token(${ctx.patientId}, ${ctx.lang}, ${purpose},
                                                        ${appointment?.id ?? null}) as token`;
    return row.token as string;
  });
  const flowIds = ctx.deps.flowIds ?? { az: env(SECRETS.flowIdAz), ru: env(SECRETS.flowIdRu) };
  const message = purpose === "book"
    ? wa.flow(t("book_flow_body", ctx.lang), flowIds[ctx.lang], token, t("book_flow_cta", ctx.lang))
    : wa.flow(
      fill(t("reschedule_flow_body", ctx.lang), { appointment: describe(appointment!, ctx.lang) }),
      flowIds[ctx.lang], token, t("reschedule_flow_cta", ctx.lang),
    );
  await reply(ctx, message);
}

async function startReschedule(ctx: Ctx): Promise<void> {
  const appointment = await findAppointment(ctx, null);
  if (!appointment) return await reply(ctx, wa.text(t("no_appointment", ctx.lang)));
  if (!appointment.canChange) {
    return await reply(ctx, wa.text(fill(t("cannot_change", ctx.lang), { appointment: describe(appointment, ctx.lang) })));
  }
  await sendFlow(ctx, "reschedule", appointment);
}

// =============================================================================
// Cancel
// =============================================================================
async function askCancel(ctx: Ctx, appointmentId: string | null): Promise<void> {
  const appointment = await findAppointment(ctx, appointmentId);
  if (!appointment) return await reply(ctx, wa.text(t("no_appointment", ctx.lang)));
  const text = { appointment: describe(appointment, ctx.lang) };
  if (!appointment.canChange) return await reply(ctx, wa.text(fill(t("cannot_change", ctx.lang), text)));

  await reply(ctx, wa.buttons(fill(t("cancel_confirm", ctx.lang), text), [
    { id: `cancel:yes:${appointment.id}:${appointment.version}`, title: t("cancel_yes", ctx.lang) },
    { id: "cancel:no", title: t("cancel_no", ctx.lang) },
  ]));
}

async function doCancel(ctx: Ctx, appointmentId: string, version: number): Promise<void> {
  try {
    const [row] = await withClinic(ctx.clinicId, (tx) =>
      tx`select core.cancel_appointment(${appointmentId}, ${ctx.patientId}, ${version}, 'patient') as ok`
    );
    if (row.ok) return await reply(ctx, wa.text(t("cancelled_ok", ctx.lang)));
  } catch (error) {
    if (sqlState(error) !== "DP001") throw error;
    const appointment = await findAppointment(ctx, appointmentId);
    const text = { appointment: appointment ? describe(appointment, ctx.lang) : "" };
    return await reply(ctx, wa.text(fill(t("cannot_change", ctx.lang), text)));
  }
  // Changed meanwhile (stale version) or not cancellable: let a human sort it out.
  await handOver(ctx, "cancel_failed");
  await reply(ctx, wa.text(t("cancel_failed", ctx.lang)));
}

// =============================================================================
// Knowledge base answers (approved text only)
// =============================================================================
async function sendKnowledge(ctx: Ctx, topic: "hours" | "location"): Promise<void> {
  const rows = await withClinic(ctx.clinicId, (tx) =>
    tx`select answer from core.kb_for_prompt(${ctx.lang}) where topic = ${topic}`
  );
  if (rows.length === 0) {
    await handOver(ctx, `kb_missing:${topic}`);
    return await reply(ctx, wa.text(t("kb_missing", ctx.lang)));
  }
  await reply(ctx, wa.text(rows.map((r) => r.answer).join("\n\n")));
}

// =============================================================================
// Conversation state
// =============================================================================
async function escalate(ctx: Ctx, reason: string): Promise<void> {
  const [row] = await withClinic(ctx.clinicId, (tx) =>
    tx`select core.set_conversation_status(${ctx.conversationId}, 'escalated', ${reason}) as changed`
  );
  ctx.conversationStatus = "escalated";
  // Only the first emergency message gets the safety reply; staff are alerted by the database.
  if (!row.changed) return;

  // The fixed emergency text (clinic setting) is the ONE message that skips shadow
  // mode (decision S1): the database queues it as pending, never as a draft.
  const [queued] = await withClinic(ctx.clinicId, (tx) =>
    tx`select * from core.queue_emergency_reply(${ctx.patientId}, ${`reply:${ctx.messageId}:emergency`})`
  );
  if (["pending", "failed"].includes(queued.delivery_status)) {
    await sendQueued(ctx.deps.sender, ctx.clinicId, queued.message_id);
  }
}

async function handOver(ctx: Ctx, reason: string): Promise<void> {
  if (ctx.conversationStatus !== "assistant") return;   // already with a human
  await withClinic(ctx.clinicId, (tx) =>
    tx`select core.set_conversation_status(${ctx.conversationId}, 'handed_to_staff', ${reason})`
  );
  ctx.conversationStatus = "handed_to_staff";
}

async function assistantMayReply(ctx: Ctx): Promise<boolean> {
  const [row] = await withClinic(ctx.clinicId, (tx) =>
    tx`select core.assistant_may_reply(${ctx.conversationId}) as ok`
  );
  return row.ok;
}

async function setLanguage(ctx: Ctx, lang: Lang): Promise<void> {
  await withClinic(ctx.clinicId, (tx) =>
    tx`update core.patients set preferred_language = ${lang} where id = ${ctx.patientId}`
  );
  ctx.lang = lang;
}

// =============================================================================
// Menu and replies
// =============================================================================
async function sendMenu(ctx: Ctx): Promise<void> {
  const l = ctx.lang;
  const other: Lang = l === "az" ? "ru" : "az";
  await reply(ctx, wa.list(t("menu_body", l), t("menu_button", l), [
    { id: "menu:book", title: t("menu_book", l) },
    { id: "menu:reschedule", title: t("menu_reschedule", l) },
    { id: "menu:cancel", title: t("menu_cancel", l) },
    { id: "menu:hours", title: t("menu_hours", l) },
    { id: "menu:location", title: t("menu_location", l) },
    { id: "menu:staff", title: t("menu_staff", l) },
    { id: `menu:lang:${other}`, title: t("menu_other_language", l) },
  ]));
}

async function reply(ctx: Ctx, message: OutboundMessage): Promise<void> {
  ctx.replies += 1;
  await sendRecorded(ctx.deps.sender, {
    clinicId: ctx.clinicId,
    patientId: ctx.patientId,
    message,
    sendKey: `reply:${ctx.messageId}:${ctx.replies}`,
  });
}

// =============================================================================
// Appointment lookups
// =============================================================================
export interface AppointmentInfo {
  id: string;
  version: number;
  status: string;
  service: string;
  dentist: string;
  localStart: string;     // "YYYY-MM-DDTHH:MI"
  canChange: boolean;
}

/** Details for messages; also used by run-jobs. */
export async function appointmentDetails(tx: Tx, appointmentId: string): Promise<AppointmentInfo | null> {
  const [row] = await tx`
    select d.appointment_id, d.version, d.status, d.service_name, d.professional_name,
           to_char(d.local_start, 'YYYY-MM-DD"T"HH24:MI') as local_start,
           core.patient_can_change(d.appointment_id) as can_change
      from core.appointment_message_details(${appointmentId}) d`;
  return row ? toInfo(row) : null;
}

/** A specific active appointment of this patient, or their next upcoming one. */
async function findAppointment(ctx: Ctx, appointmentId: string | null): Promise<AppointmentInfo | null> {
  return await withClinic(ctx.clinicId, async (tx) => {
    const [row] = await tx`
      select a.id from core.appointments a
       where a.patient_id = ${ctx.patientId}
         and a.status in ('pending_approval', 'booked', 'confirmed')
         and a.start_at > now()
         and (${appointmentId}::uuid is null or a.id = ${appointmentId}::uuid)
       order by a.start_at
       limit 1`;
    return row ? await appointmentDetails(tx, row.id) : null;
  });
}

function toInfo(row: Record<string, unknown>): AppointmentInfo {
  return {
    id: String(row.appointment_id),
    version: Number(row.version),
    status: String(row.status),
    service: String(row.service_name),
    dentist: String(row.professional_name),
    localStart: String(row.local_start),
    canChange: Boolean(row.can_change),
  };
}

export function placeholders(a: AppointmentInfo, lang: Lang): Record<string, string> {
  return {
    service: a.service,
    dentist: a.dentist,
    date: formatDate(a.localStart, lang),
    time: formatTime(a.localStart),
  };
}

function describe(a: AppointmentInfo, lang: Lang): string {
  return `${formatDate(a.localStart, lang)}, ${formatTime(a.localStart)} — ${a.service}`;
}
