// Every call the app makes to the database, in one place.
//
// RPCS lists each function with its exact parameter names; a test checks this
// list against the SQL migrations, so a renamed parameter fails the build
// instead of failing in the clinic.

import { functionsUrl, supabase } from "./supabase";

export const RPCS = {
  my_staff_profile: { schema: "ops", params: [] },
  staff_counts: { schema: "core", params: [] },
  staff_draft_inbox: { schema: "core", params: [] },
  approve_draft: { schema: "core", params: ["p_message_id", "p_new_text"] },
  discard_draft: { schema: "core", params: ["p_message_id"] },
  staff_pending_bookings: { schema: "core", params: [] },
  approve_appointment: { schema: "core", params: ["p_appointment_id", "p_expected_version", "p_duration_minutes"] },
  reject_appointment: { schema: "core", params: ["p_appointment_id", "p_expected_version", "p_reason"] },
  staff_conversations: { schema: "core", params: ["p_filter", "p_limit"] },
  staff_conversation_info: { schema: "core", params: ["p_conversation_id"] },
  staff_conversation_messages: { schema: "core", params: ["p_conversation_id", "p_limit"] },
  staff_send_reply: { schema: "core", params: ["p_conversation_id", "p_text"] },
  set_conversation_status: { schema: "core", params: ["p_conversation_id", "p_status", "p_reason"] },
  staff_day_schedule: { schema: "core", params: ["p_local_date", "p_professional_id"] },
  staff_set_appointment_status: { schema: "core", params: ["p_appointment_id", "p_expected_version", "p_status"] },
  register_push_subscription: { schema: "ops", params: ["p_endpoint", "p_p256dh", "p_auth", "p_user_agent"] },
  mark_notifications_read: { schema: "ops", params: ["p_notification_ids"] },
} as const;

export type RpcName = keyof typeof RPCS;

// ---------------------------------------------------------------- errors
export type ErrorKind = "window_closed" | "overlap" | "stale" | "network" | "other";

export class AppError extends Error {
  constructor(readonly kind: ErrorKind, message: string) {
    super(message);
  }
}

/** Map a Postgres / network error to something staff can act on. */
export function toAppError(error: { code?: string; message?: string } | null | undefined): AppError {
  const code = error?.code ?? "";
  if (code === "DP002") return new AppError("window_closed", error?.message ?? "");
  if (code === "23P01") return new AppError("overlap", error?.message ?? "");
  if (code === "40001") return new AppError("stale", error?.message ?? "");
  if (/fetch|network/i.test(error?.message ?? "")) return new AppError("network", error?.message ?? "");
  return new AppError("other", error?.message ?? "unknown error");
}

async function rpc<T>(name: RpcName, args: Record<string, unknown> = {}): Promise<T> {
  const { schema } = RPCS[name];
  const { data, error } = await supabase.schema(schema).rpc(name, args);
  if (error) throw toAppError(error);
  return data as T;
}

/** Functions returning boolean "did it change": false means someone else changed it first. */
async function changed(name: RpcName, args: Record<string, unknown>): Promise<void> {
  const ok = await rpc<boolean>(name, args);
  if (ok === false) throw new AppError("stale", `${name} returned false`);
}

// ---------------------------------------------------------------- types
export interface Profile {
  clinic_id: string; clinic_name: string; timezone: string; role: "dentist" | "receptionist" | "admin";
  professional_id: string | null; professional_name: string | null; shadow_mode: boolean;
}
export interface Counts { drafts: number; pending_bookings: number; attention: number; unread_notifications: number }
export interface Draft {
  message_id: string; conversation_id: string; patient_id: string; patient_name: string | null; wa_id: string;
  language: string; kind: string; body: string | null; template_name: string | null; editable: boolean;
  created_at: string; replying_to: string | null; conversation_status: string; window_open: boolean;
}
export interface PendingBooking {
  appointment_id: string; version: number; patient_name: string | null; wa_id: string; service_name: string;
  service_minutes: number; buffer_minutes: number; professional_id: string; professional_name: string;
  local_start: string; held_minutes: number; max_duration_minutes: number; requested_at: string; booked_by: string;
}
export interface ConversationRow {
  conversation_id: string; patient_name: string | null; wa_id: string; status: string; status_reason: string | null;
  last_message_at: string; last_preview: string | null; last_direction: string | null; drafts: number; version: number;
}
export interface ConversationInfo {
  conversation_id: string; patient_name: string | null; wa_id: string; language: string; status: string;
  status_reason: string | null; version: number; window_open: boolean;
}
export interface Message {
  message_id: string; direction: "in" | "out"; source: string; kind: string; body: string | null;
  template_name: string | null; delivery_status: string | null; edited: boolean; created_at: string;
}
export interface DayRow {
  appointment_id: string; version: number; local_start: string; local_end: string; patient_name: string | null;
  wa_id: string; service_name: string; professional_id: string; professional_name: string; status: string; booked_by: string;
}
export interface CalendarLink { professional_id: string; google_email: string | null; status: string }
export interface Professional { id: string; display_name: string }
export interface ClinicSettings { shadow_mode: boolean; all_bookings_need_approval: boolean }

// ---------------------------------------------------------------- calls
export const api = {
  profile: () => rpc<Profile[]>("my_staff_profile"),
  counts: async () => (await rpc<Counts[]>("staff_counts"))[0],

  drafts: () => rpc<Draft[]>("staff_draft_inbox"),
  approveDraft: (id: string, newText: string | null) => changed("approve_draft", { p_message_id: id, p_new_text: newText }),
  discardDraft: (id: string) => changed("discard_draft", { p_message_id: id }),

  pendingBookings: () => rpc<PendingBooking[]>("staff_pending_bookings"),
  approveBooking: (id: string, version: number, minutes: number) =>
    changed("approve_appointment", { p_appointment_id: id, p_expected_version: version, p_duration_minutes: minutes }),
  rejectBooking: (id: string, version: number, reason: string | null) =>
    changed("reject_appointment", { p_appointment_id: id, p_expected_version: version, p_reason: reason }),

  conversations: (filter: "attention" | "open" | "all") =>
    rpc<ConversationRow[]>("staff_conversations", { p_filter: filter, p_limit: 100 }),
  conversationInfo: async (id: string) => (await rpc<ConversationInfo[]>("staff_conversation_info", { p_conversation_id: id }))[0] ?? null,
  messages: (id: string) => rpc<Message[]>("staff_conversation_messages", { p_conversation_id: id, p_limit: 200 }),
  sendReply: (id: string, text: string) => rpc<string>("staff_send_reply", { p_conversation_id: id, p_text: text }),
  setConversationStatus: (id: string, status: "assistant" | "closed") =>
    changed("set_conversation_status", { p_conversation_id: id, p_status: status, p_reason: "staff" }),

  daySchedule: (date: string, professionalId: string | null) =>
    rpc<DayRow[]>("staff_day_schedule", { p_local_date: date, p_professional_id: professionalId }),
  setAppointmentStatus: (id: string, version: number, status: string) =>
    changed("staff_set_appointment_status", { p_appointment_id: id, p_expected_version: version, p_status: status }),

  registerPush: (sub: { endpoint: string; p256dh: string; auth: string }) =>
    rpc<string>("register_push_subscription", {
      p_endpoint: sub.endpoint, p_p256dh: sub.p256dh, p_auth: sub.auth, p_user_agent: navigator.userAgent.slice(0, 200),
    }),

  professionals: async (): Promise<Professional[]> => {
    const { data, error } = await supabase.schema("core").from("professionals")
      .select("id, display_name").eq("active", true).order("sort_order");
    if (error) throw toAppError(error);
    return data ?? [];
  },
  calendarLinks: async (): Promise<CalendarLink[]> => {
    const { data, error } = await supabase.schema("ops").from("google_calendar_links")
      .select("professional_id, google_email, status");
    if (error) throw toAppError(error);
    return data ?? [];
  },
  clinicSettings: async (clinicId: string): Promise<ClinicSettings> => {
    const { data, error } = await supabase.schema("core").from("clinics")
      .select("shadow_mode, all_bookings_need_approval").eq("id", clinicId).single();
    if (error) throw toAppError(error);
    return data as ClinicSettings;
  },
  updateClinicSettings: async (clinicId: string, patch: Partial<ClinicSettings>): Promise<void> => {
    const { error } = await supabase.schema("core").from("clinics").update(patch).eq("id", clinicId);
    if (error) throw toAppError(error);
  },

  /** Start connecting a dentist's Google Calendar; returns Google's consent URL. */
  googleConnectUrl: async (professionalId: string): Promise<string> => {
    const { data } = await supabase.auth.getSession();
    const response = await fetch(`${functionsUrl}/google-oauth/start`, {
      method: "POST",
      headers: { Authorization: `Bearer ${data.session?.access_token ?? ""}`, "Content-Type": "application/json" },
      body: JSON.stringify({ professional_id: professionalId }),
    });
    if (!response.ok) throw new AppError("other", `google-oauth/start ${response.status}`);
    return (await response.json()).url;
  },
};

export type Api = typeof api;
