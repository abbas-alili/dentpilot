// Every patient-facing sentence the deterministic assistant sends, in
// Azerbaijani and Russian. STATUS: DRAFT — NEEDS RECEPTIONIST REVIEW before
// go-live (wording, register, and the emergency number).
//
// WhatsApp limits (checked by tests): list row title ≤ 24 chars, reply
// button title ≤ 20, list button label ≤ 20, Flow CTA ≤ 20.

import type { Lang } from "./i18n.ts";

export const TEXTS = {
  // ---------------------------------------------------------------- menu
  menu_body: {
    az: "Salam! Sizə necə kömək edə bilərik? Menyudan seçin.",
    ru: "Здравствуйте! Чем мы можем помочь? Выберите пункт меню.",
  },
  menu_button: { az: "Menyu", ru: "Меню" },
  menu_book: { az: "Randevu al", ru: "Записаться" },
  menu_reschedule: { az: "Randevumu dəyiş", ru: "Перенести запись" },
  menu_cancel: { az: "Randevumu ləğv et", ru: "Отменить запись" },
  menu_hours: { az: "İş saatları", ru: "Часы работы" },
  menu_location: { az: "Ünvan", ru: "Адрес" },
  menu_staff: { az: "Administratorla əlaqə", ru: "Связь с администратором" },
  menu_other_language: { az: "Русский язык", ru: "Azərbaycan dili" },

  // ---------------------------------------------------------------- booking (Flow)
  book_flow_body: { az: "Xidməti, həkimi və vaxtı seçin.", ru: "Выберите услугу, врача и время." },
  book_flow_cta: { az: "Randevu al", ru: "Записаться" },
  reschedule_flow_body: {
    az: "Randevunuz: {appointment}.\nYeni vaxt seçin.",
    ru: "Ваша запись: {appointment}.\nВыберите новое время.",
  },
  reschedule_flow_cta: { az: "Vaxtı dəyiş", ru: "Изменить время" },
  booking_confirmed: {
    az: "Randevunuz təsdiqləndi ✅\n{service}\n{date}, {time}\n{dentist}",
    ru: "Вы записаны ✅\n{service}\n{date}, {time}\n{dentist}",
  },
  booking_pending: {
    az: "Sorğunuzu aldıq: {service}, {date}, {time}.\nHəkim təsdiqlədikdən sonra sizə xəbər verəcəyik.",
    ru: "Мы получили вашу заявку: {service}, {date}, {time}.\nСообщим, когда врач подтвердит.",
  },
  hold_expired: {
    az: "Seçdiyiniz vaxtın saxlanma müddəti bitdi. Zəhmət olmasa, vaxtı yenidən seçin.",
    ru: "Время брони истекло. Пожалуйста, выберите время ещё раз.",
  },

  // Flow screens (data we send; static Flow labels live in the published Flow JSON)
  flow_dentist_any: { az: "Fərqi yoxdur", ru: "Не важно" },
  flow_summary: {
    az: "{service} · {duration} dəq\n{date} · {time}\n{dentist}",
    ru: "{service} · {duration} мин\n{date} · {time}\n{dentist}",
  },
  flow_hold_note: {
    az: "Bu vaxt sizin üçün {minutes} dəqiqə saxlanılır.",
    ru: "Это время забронировано для вас на {minutes} минут.",
  },
  flow_slot_taken: {
    az: "Bu saat artıq tutulub. Başqa saat seçin.",
    ru: "Это время уже занято. Выберите другое.",
  },
  flow_no_dates: {
    az: "Yaxın günlərdə boş vaxt yoxdur. Administrator sizə yazacaq.",
    ru: "В ближайшие дни нет свободного времени. Администратор вам напишет.",
  },

  // ---------------------------------------------------------------- change / cancel
  no_appointment: { az: "Qarşıdakı randevunuz tapılmadı.", ru: "У вас нет предстоящих записей." },
  cannot_change: {
    az: "Randevunuza ({appointment}) az vaxt qalıb, onu buradan dəyişmək mümkün deyil. Zəhmət olmasa, klinikaya zəng edin.",
    ru: "До вашей записи ({appointment}) осталось мало времени, изменить её здесь нельзя. Пожалуйста, позвоните в клинику.",
  },
  cancel_confirm: { az: "Bu randevunu ləğv edək?\n{appointment}", ru: "Отменить эту запись?\n{appointment}" },
  cancel_yes: { az: "Bəli, ləğv et", ru: "Да, отменить" },
  cancel_no: { az: "Xeyr", ru: "Нет" },
  cancelled_ok: { az: "Randevunuz ləğv edildi.", ru: "Ваша запись отменена." },
  cancel_failed: {
    az: "Randevunu ləğv etmək alınmadı. Administrator sizə yazacaq.",
    ru: "Не удалось отменить запись. Администратор вам напишет.",
  },
  kept: { az: "Yaxşı, randevunuz qüvvədə qalır.", ru: "Хорошо, запись остаётся в силе." },
  attendance_confirmed: { az: "Təşəkkür edirik, sizi gözləyirik!", ru: "Спасибо, ждём вас!" },

  // ---------------------------------------------------------------- hand-over & safety
  staff_will_reply: {
    az: "Mesajınızı administratora ötürdük, tezliklə cavab verəcək.",
    ru: "Мы передали ваше сообщение администратору, он скоро ответит.",
  },
  // The emergency reply is NOT here: it is a clinic setting (core.clinics.emergency_reply_az/_ru),
  // sent immediately even in shadow mode. See migration 20261103100000.
  media_received: {
    az: "Faylı aldıq və administratora ötürdük.",
    ru: "Мы получили файл и передали его администратору.",
  },
  clinical_to_staff: {
    az: "Bu sualı həkimə ötürdük, sizə cavab yazacaq.",
    ru: "Мы передали ваш вопрос врачу, он вам ответит.",
  },
  you_are_welcome: {
    az: "Buyurun! Başqa sualınız olsa, yazın.",
    ru: "Пожалуйста! Если будут вопросы, пишите.",
  },
  kb_missing: {
    az: "Bu məlumatı administrator sizə yazacaq.",
    ru: "Эту информацию вам пришлёт администратор.",
  },

  // ---------------------------------------------------------------- reminders opt-out
  opted_out: { az: "Xatırlatmaları dayandırdıq.", ru: "Мы больше не будем присылать напоминания." },
  opted_in: { az: "Xatırlatmalar yenidən aktivdir.", ru: "Напоминания снова включены." },

  // ---------------------------------------------------------------- approval results (inside 24 h window)
  approved: {
    az: "Həkim randevunuzu təsdiqlədi ✅\n{service}\n{date}, {time}\n{dentist}",
    ru: "Врач подтвердил вашу запись ✅\n{service}\n{date}, {time}\n{dentist}",
  },
  rejected: {
    az: "Təəssüf ki, {date}, {time} üçün randevunu təsdiqləyə bilmədik. Başqa vaxt seçmək üçün menyudan «Randevu al» seçin.",
    ru: "К сожалению, мы не можем подтвердить запись на {date}, {time}. Чтобы выбрать другое время, нажмите «Записаться» в меню.",
  },
} as const satisfies Record<string, Record<Lang, string>>;

export type TextKey = keyof typeof TEXTS;

export function t(key: TextKey, lang: Lang): string {
  return TEXTS[key][lang];
}

// ---------------------------------------------------------------- Meta templates
// Must be created and approved in WhatsApp Manager under these names, in "az"
// and "ru", with the body variables in exactly this order. Drafts: SOP.md,
// "WhatsApp templates".
export const META_TEMPLATES = {
  /** {{1}} service · {{2}} date · {{3}} time · {{4}} dentist; quick replies: [confirm, cancel] */
  reminder: "dentpilot_reminder",
  /** same variables, no buttons (clinic setting reminder_ask_confirmation = false) */
  reminderPlain: "dentpilot_reminder_plain",
  /** {{1}} service · {{2}} date · {{3}} time · {{4}} dentist */
  approved: "dentpilot_booking_approved",
  /** {{1}} date · {{2}} time */
  rejected: "dentpilot_booking_rejected",
} as const;

// ---------------------------------------------------------------- staff push (Azerbaijani)
export const PUSH_TEXTS: Record<string, { title: string; body: string }> = {
  escalation: { title: "⚠️ Təcili mesaj", body: "Pasiyent təcili yardım istəyə bilər. Söhbəti açın." },
  handover: { title: "Administrator lazımdır", body: "Pasiyent administratorla danışmaq istəyir." },
  pending_approval: { title: "Yeni randevu sorğusu", body: "Təsdiq gözləyən randevu var." },
  approval_reminder: { title: "Təsdiq gözləyir", body: "Randevu sorğusu hələ təsdiqlənməyib." },
  draft_waiting: { title: "Cavab təsdiq gözləyir", body: "Botun hazırladığı cavabı yoxlayıb göndərin." },
  calendar_disconnected: { title: "Google Təqvim ayrılıb", body: "Təqvimi yenidən qoşun, yoxsa randevular görünməyəcək." },
};
