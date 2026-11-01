// flow-endpoint — data endpoint for the booking Flow (contract: 04-booking-flow-endpoint-contract.md).
// Connects as dentpilot_agent.
//
//   decrypt (RSA-OAEP + AES-GCM) ─▶ ping | error notice | INIT | BACK | data_exchange(step)
//   step "dates" → dates with free slots      step "slots" → free times
//   step "hold"  → reserve 10 min → SCREEN_CONFIRM, or back to SCREEN_SLOT if taken
//   respond encrypted with the flipped IV
//
// HTTP codes Meta understands: 421 = cannot decrypt (client refreshes the
// public key), 427 = flow token invalid/expired, 432 = bad request signature.
// Everything else is 200.
// The clinic, patient and language come ONLY from the server-side flow token.

import { clinicForFlowToken, sqlState, type Tx, withClinic } from "../_shared/db.ts";
import { decryptFlowRequest, encryptFlowResponse, verifyMetaSignature } from "../_shared/crypto.ts";
import { fill, formatDate, formatTime, type Lang } from "../_shared/i18n.ts";
import { log } from "../_shared/log.ts";
import { t } from "../_shared/texts.ts";

export interface FlowDeps {
  privateKey: CryptoKey;
  appSecret: string;
  verifySignature: boolean;
}

type FlowRequest = {
  version?: string;
  action?: string;
  screen?: string;
  flow_token?: string;
  data?: Record<string, unknown>;
};

type FlowResponse = { version?: string; screen?: string; data: Record<string, unknown> };

interface Session {
  clinicId: string;
  patientId: string;
  lang: Lang;
  purpose: "book" | "reschedule";
  appointmentId: string | null;
}

class InvalidToken extends Error {}

export function createFlowHandler(deps: FlowDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
    const raw = await req.text();

    if (deps.verifySignature &&
        !(await verifyMetaSignature(deps.appSecret, raw, req.headers.get("x-hub-signature-256")))) {
      log.warn("flow.bad_signature");
      return new Response("invalid signature", { status: 432 });   // Meta's code for a bad signature
    }

    let decrypted;
    try {
      decrypted = await decryptFlowRequest(JSON.parse(raw), deps.privateKey);
    } catch (error) {
      log.warn("flow.decrypt_failed", { error: String(error) });
      return new Response("cannot decrypt", { status: 421 });
    }

    let response: FlowResponse;
    try {
      response = await route(decrypted.payload as FlowRequest);
    } catch (error) {
      if (error instanceof InvalidToken) return new Response("invalid flow token", { status: 427 });
      log.error("flow.failed", { error: String(error) });
      return new Response("error", { status: 500 });
    }

    const body = await encryptFlowResponse(response, decrypted.aesKey, decrypted.iv);
    return new Response(body, { status: 200, headers: { "Content-Type": "text/plain" } });
  };
}

// =============================================================================
// Routing
// =============================================================================
async function route(req: FlowRequest): Promise<FlowResponse> {
  const version = req.version ?? "3.0";

  if (req.action === "ping") return { data: { status: "active" } };
  if (req.data && "error" in req.data) {
    log.warn("flow.client_error", { error: String(req.data.error) });
    return { data: { acknowledged: true } };
  }

  const session = await loadSession(req.flow_token);

  if (req.action === "INIT" || req.action === "BACK") {
    return { version, ...await screenService(session) };
  }

  if (req.action === "data_exchange") {
    const data = req.data ?? {};
    switch (data.step) {
      case "dates": return { version, ...await screenSlot(session, str(data.service), str(data.dentist), null) };
      case "slots": return { version, ...await screenSlot(session, str(data.service), str(data.dentist), str(data.date)) };
      case "hold": return { version, ...await hold(session, data) };
    }
  }

  log.warn("flow.unknown_action", { action: req.action });
  return { version, ...await screenService(session) };
}

async function loadSession(token: string | undefined): Promise<Session> {
  if (!token) throw new InvalidToken();
  const clinicId = await clinicForFlowToken(token);
  if (!clinicId) throw new InvalidToken();
  const [row] = await withClinic(clinicId, (tx) => tx`select * from core.read_flow_token(${token})`);
  if (!row) throw new InvalidToken();
  return {
    clinicId,
    patientId: row.patient_id,
    lang: row.language === "ru" ? "ru" : "az",
    purpose: row.purpose,
    appointmentId: row.appointment_id,
  };
}

// =============================================================================
// Screens
// =============================================================================
async function screenService(s: Session): Promise<Omit<FlowResponse, "version">> {
  return await withClinic(s.clinicId, async (tx) => {
    const services = await tx`
      select code as id, case when ${s.lang} = 'ru' then name_ru else name_az end as title
        from core.services where active and bookable_by_patient order by sort_order, code`;
    const dentists = await tx`
      select id::text, display_name as title from core.professionals where active order by sort_order, display_name`;
    const [clinic] = await tx`select offer_any_dentist from core.clinics where id = core.current_clinic_id()`;
    const any = clinic.offer_any_dentist ? [{ id: "any", title: t("flow_dentist_any", s.lang) }] : [];
    return {
      screen: "SCREEN_SERVICE",
      data: {
        services: services.map((r) => ({ id: r.id, title: r.title })),
        dentists: [...any, ...dentists.map((r) => ({ id: r.id, title: r.title }))],
      },
    };
  });
}

async function screenSlot(
  s: Session, serviceCode: string, dentist: string, date: string | null, errorMessage?: string,
): Promise<Omit<FlowResponse, "version">> {
  return await withClinic(s.clinicId, async (tx) => {
    const serviceId = await serviceIdFor(tx, serviceCode);
    const professionalId = professionalOrNull(dentist);
    const ignore = s.appointmentId;

    const dates = serviceId
      ? await tx`select local_date::text as id from core.available_dates(${serviceId}, ${professionalId}::uuid, null, 10)`
      : [];

    let slots: { id: string; title: string }[] = [];
    if (date && serviceId && /^\d{4}-\d{2}-\d{2}$/.test(date)) {
      const rows = await tx`
        select distinct to_char(a.start_at at time zone c.timezone, 'YYYY-MM-DD"T"HH24:MI') as id
          from core.available_slots(${serviceId}, ${date}::date, ${professionalId}::uuid, ${ignore}::uuid) a
         cross join core.clinics c
         where c.id = core.current_clinic_id()
         order by 1
         limit 20`;
      slots = rows.map((r) => ({ id: r.id, title: formatTime(r.id) }));
    }

    const data: Record<string, unknown> = {
      service: serviceCode,
      dentist,
      dates: dates.map((r) => ({ id: r.id, title: formatDate(r.id, s.lang) })),
      slots,
      slots_visible: slots.length > 0,
      has_error: false,
      error_message: "",
    };
    const problem = errorMessage ?? (dates.length === 0 ? t("flow_no_dates", s.lang) : null);
    if (problem) Object.assign(data, { has_error: true, error_message: problem });
    return { screen: "SCREEN_SLOT", data };
  });
}

async function hold(s: Session, data: Record<string, unknown>): Promise<Omit<FlowResponse, "version">> {
  const serviceCode = str(data.service);
  const dentist = str(data.dentist);
  const slot = Array.isArray(data.slot) ? str(data.slot[0]) : str(data.slot);   // ChipsSelector sends an array
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(slot)) {
    return await screenSlot(s, serviceCode, dentist, str(data.date), t("flow_slot_taken", s.lang));
  }

  const held = await withClinic(s.clinicId, async (tx) => {
    const serviceId = await serviceIdFor(tx, serviceCode);
    if (!serviceId) return null;
    const [row] = await tx`
      select core.hold_slot(${s.patientId}, ${serviceId}, (${slot}::timestamp at time zone c.timezone),
                            ${professionalOrNull(dentist)}::uuid, ${s.appointmentId}::uuid) as hold_id
        from core.clinics c where c.id = core.current_clinic_id()`;
    if (!row?.hold_id) return null;
    const [info] = await tx`
      select h.id::text as hold_id, pr.display_name as dentist, c.hold_minutes,
             case when ${s.lang} = 'ru' then sv.name_ru else sv.name_az end as service, sv.duration_minutes,
             p.display_name as patient_name
        from core.slot_holds h
        join core.professionals pr on pr.id = h.professional_id
        join core.services sv      on sv.id = h.service_id
        join core.patients p       on p.id  = h.patient_id
        join core.clinics c        on c.id  = h.clinic_id
       where h.id = ${row.hold_id}`;
    return info;
  }).catch((error) => {
    // P0002: the appointment being rescheduled is no longer active; DP001: inside the cutoff.
    if (["P0002", "DP001"].includes(sqlState(error) ?? "")) return null;
    throw error;
  });

  if (!held) {
    // Taken meanwhile (or invalid choice): show fresh times for the same date.
    return await screenSlot(s, serviceCode, dentist, slot.slice(0, 10), t("flow_slot_taken", s.lang));
  }

  return {
    screen: "SCREEN_CONFIRM",
    data: {
      summary: fill(t("flow_summary", s.lang), {
        service: held.service, duration: held.duration_minutes,
        date: formatDate(slot, s.lang), time: formatTime(slot), dentist: held.dentist,
      }),
      patient_name: held.patient_name ?? "",
      hold_note: fill(t("flow_hold_note", s.lang), { minutes: held.hold_minutes }),
      hold_id: held.hold_id,
    },
  };
}

// =============================================================================
// Helpers
// =============================================================================
async function serviceIdFor(tx: Tx, code: string): Promise<string | null> {
  const [row] = await tx`select id from core.services where code = ${code} and active and bookable_by_patient`;
  return row?.id ?? null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** "any" or anything that isn't a uuid → null (any dentist). Never trust client ids. */
function professionalOrNull(dentist: string): string | null {
  return UUID.test(dentist) ? dentist : null;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}
