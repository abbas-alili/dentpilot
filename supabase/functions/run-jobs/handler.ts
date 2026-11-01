// run-jobs — works the ops.background_jobs queue (SOP §5c). Called every
// minute by pg_cron (dentpilot-tick) with the cron secret. Connects as
// dentpilot_agent: claims through ops functions, then does each job inside
// that job's clinic.
//
//   process_message    → the normal pipeline
//   send_reminder      → approved template (+ confirm/cancel buttons)
//   notify_patient     → approved/rejected: free text inside 24 h, template outside
//   approval_reminder  → ops.run_approval_reminder (database only)
//   push_notification  → web push to each of the staff member's devices
//   send_message       → send an approved draft or a staff reply
//   gcal_sync          → write the appointment to the dentist's Google Calendar
//
// A handler that throws → fail_job (backoff, dead after max attempts).

import { withClinic, withoutClinic } from "../_shared/db.ts";
import { constantTimeEqual } from "../_shared/crypto.ts";
import { fill, formatDate, formatTime, type Lang } from "../_shared/i18n.ts";
import { log } from "../_shared/log.ts";
import { sendQueued, sendRecorded } from "../_shared/outbound.ts";
import { GoogleAuthRevoked, type GoogleCalendarClient } from "../_shared/gcal.ts";
import { appointmentDetails, type PipelineDeps, placeholders, processInbound } from "../_shared/pipeline.ts";
import type { PushSender } from "../_shared/push.ts";
import { META_TEMPLATES, PUSH_TEXTS, t } from "../_shared/texts.ts";
import { wa } from "../_shared/whatsapp.ts";

export interface JobsDeps extends PipelineDeps {
  cronSecret: string;
  push: PushSender;
  /** Absent when Google Calendar isn't configured: gcal_sync jobs then complete as no-ops. */
  google?: GoogleCalendarClient;
  /** Stop claiming new jobs after this long (Edge Functions have a wall-clock limit). */
  budgetMs?: number;
  workerId?: string;
}

interface Job {
  id: string;
  clinic_id: string | null;
  kind: string;
  payload: Record<string, unknown>;
  idempotency_key: string;
  attempts: number;
}

export interface RunSummary { done: number; failed: number }

export function createJobsHandler(deps: JobsDeps) {
  return async (req: Request): Promise<Response> => {
    const auth = req.headers.get("authorization") ?? "";
    if (!constantTimeEqual(auth, `Bearer ${deps.cronSecret}`)) {
      return new Response("unauthorized", { status: 401 });
    }
    const summary = await runJobs(deps);
    return Response.json(summary);
  };
}

export async function runJobs(deps: JobsDeps): Promise<RunSummary> {
  const deadline = Date.now() + (deps.budgetMs ?? 45_000);
  const worker = deps.workerId ?? `run-jobs-${crypto.randomUUID().slice(0, 8)}`;
  const summary: RunSummary = { done: 0, failed: 0 };
  const tokens = new Map<string, string>();   // Google access tokens, per dentist, for this run

  while (Date.now() < deadline) {
    const jobs = await withoutClinic((tx) =>
      tx`select id, clinic_id, kind, payload, idempotency_key, attempts
           from ops.claim_jobs(null, 10, ${worker})`
    ) as unknown as Job[];
    if (jobs.length === 0) break;

    for (const job of jobs) {
      try {
        await handleJob(deps, job, tokens);
        await withoutClinic((tx) => tx`select ops.complete_job(${job.id})`);
        summary.done++;
      } catch (error) {
        const [row] = await withoutClinic((tx) => tx`select ops.fail_job(${job.id}, ${String(error)}) as status`);
        log.warn("jobs.failed", { jobId: job.id, kind: job.kind, status: row.status, error: String(error) });
        summary.failed++;
      }
    }
  }
  return summary;
}

async function handleJob(deps: JobsDeps, job: Job, tokens: Map<string, string>): Promise<void> {
  switch (job.kind) {
    case "process_message":
      await processInbound(deps, job.clinic_id!, String(job.payload.message_id));
      return;
    case "send_reminder":
      return await sendReminder(deps, job);
    case "notify_patient":
      return await notifyPatient(deps, job);
    case "approval_reminder":
      await withoutClinic((tx) => tx`select ops.run_approval_reminder(${job.id})`);
      return;
    case "push_notification":
      return await pushNotification(deps, job);
    case "send_message":
      await sendQueued(deps.sender, job.clinic_id!, String(job.payload.message_id));
      return;
    case "gcal_sync":
      return await syncCalendar(deps, job, tokens);
    default:
      throw new Error(`unknown job kind ${job.kind}`);
  }
}

// -----------------------------------------------------------------------------
// Patient messages
// -----------------------------------------------------------------------------
interface MessageTarget {
  patientId: string;
  lang: Lang;
  optedOut: boolean;
  windowOpen: boolean;
  askConfirmation: boolean;
}

async function loadAppointment(clinicId: string, appointmentId: string) {
  return await withClinic(clinicId, async (tx) => {
    const info = await appointmentDetails(tx, appointmentId);
    if (!info) return null;
    const [d] = await tx`
      select patient_id, language, opted_out, window_open, ask_confirmation
        from core.appointment_message_details(${appointmentId})`;
    const target: MessageTarget = {
      patientId: d.patient_id, lang: d.language === "ru" ? "ru" : "az",
      optedOut: d.opted_out, windowOpen: d.window_open, askConfirmation: d.ask_confirmation,
    };
    return { info, target };
  });
}

async function sendReminder(deps: JobsDeps, job: Job): Promise<void> {
  const loaded = await loadAppointment(job.clinic_id!, String(job.payload.appointment_id));
  if (!loaded) return;
  const { info, target } = loaded;
  if (!["booked", "confirmed"].includes(info.status) || target.optedOut) return;   // nothing to send

  const params = [info.service, formatDate(info.localStart, target.lang), formatTime(info.localStart), info.dentist];
  const message = target.askConfirmation && info.status === "booked"
    ? wa.template(META_TEMPLATES.reminder, target.lang, params,
                  [`remind:confirm:${info.id}`, `remind:cancel:${info.id}`])
    : wa.template(META_TEMPLATES.reminderPlain, target.lang, params);

  await sendRecorded(deps.sender, {
    clinicId: job.clinic_id!, patientId: target.patientId, message,
    sendKey: `job:${job.idempotency_key}`, source: "system",
  });
}

async function notifyPatient(deps: JobsDeps, job: Job): Promise<void> {
  const loaded = await loadAppointment(job.clinic_id!, String(job.payload.appointment_id));
  if (!loaded) return;
  const { info, target } = loaded;
  const approved = job.payload.event === "approved";
  const values = placeholders(info, target.lang);

  const message = target.windowOpen
    ? wa.text(fill(t(approved ? "approved" : "rejected", target.lang), values))
    : approved
    ? wa.template(META_TEMPLATES.approved, target.lang, [values.service, values.date, values.time, values.dentist])
    : wa.template(META_TEMPLATES.rejected, target.lang, [values.date, values.time]);

  await sendRecorded(deps.sender, {
    clinicId: job.clinic_id!, patientId: target.patientId, message,
    sendKey: `job:${job.idempotency_key}`, source: "system",
  });
}

// -----------------------------------------------------------------------------
// Staff push
// -----------------------------------------------------------------------------
async function pushNotification(deps: JobsDeps, job: Job): Promise<void> {
  const targets = await withoutClinic((tx) =>
    tx`select * from ops.push_targets(${String(job.payload.notification_id)})`
  );
  for (const target of targets) {
    const text = PUSH_TEXTS[target.kind] ?? { title: "DentPilot", body: "" };
    const subscription = { endpoint: target.endpoint, p256dh: target.p256dh, auth: target.auth };
    const result = await deps.push.send(subscription, {
      ...text,
      kind: target.kind,
      detail: target.detail,
      conversation_id: target.conversation_id,
      appointment_id: target.appointment_id,
    });
    await withoutClinic((tx) =>
      tx`select ops.record_push_result(${target.subscription_id}, ${result.ok}, ${!result.ok && result.gone})`
    );
  }
  // Device failures are recorded per device; the job itself succeeds.
}

// -----------------------------------------------------------------------------
// Google Calendar (one-way: DentPilot → the dentist's primary calendar)
// -----------------------------------------------------------------------------
async function syncCalendar(deps: JobsDeps, job: Job, tokens: Map<string, string>): Promise<void> {
  if (!deps.google) return;   // Google not configured in this deployment
  const google = deps.google;
  const appointmentId = String(job.payload.appointment_id);

  const { event, previous } = await withClinic(job.clinic_id!, async (tx) => {
    const [event] = await tx`select * from core.calendar_event_for(${appointmentId})`;
    const [previous] = await tx`select * from ops.gcal_event_for(${appointmentId})`;
    return { event, previous };
  });

  /** Access token for a dentist, or null if they have no working link. */
  const tokenFor = async (professionalId: string): Promise<{ token: string; calendarId: string } | null> => {
    const [link] = await withoutClinic((tx) => tx`select * from ops.google_link_for(${professionalId})`);
    if (!link || link.status !== "active") return null;
    try {
      if (!tokens.has(professionalId)) tokens.set(professionalId, await google.accessToken(link.refresh_token));
      return { token: tokens.get(professionalId)!, calendarId: link.calendar_id };
    } catch (error) {
      if (!(error instanceof GoogleAuthRevoked)) throw error;
      await withoutClinic((tx) => tx`select ops.mark_google_link_broken(${professionalId}, ${String(error)})`);
      return null;
    }
  };

  // Moved to another dentist, or no longer active: remove the old event.
  const stillWanted = event?.active && event.professional_id === previous?.professional_id;
  if (previous && !stillWanted) {
    const old = await tokenFor(previous.professional_id);
    if (old) await google.deleteEvent(old.token, old.calendarId, previous.event_id);
    await withoutClinic((tx) => tx`select ops.forget_gcal_event(${appointmentId})`);
  }
  if (!event?.active) return;

  const target = await tokenFor(event.professional_id);
  if (!target) return;
  const eventId = await google.upsertEvent(target.token, target.calendarId, {
    appointmentId, summary: event.summary, startsAt: event.starts_at, endsAt: event.ends_at,
    tentative: event.tentative, timezone: event.timezone,
  });
  await withoutClinic((tx) =>
    tx`select ops.record_gcal_event(${appointmentId}, ${event.professional_id}, ${eventId}, ${event.version})`
  );
}
