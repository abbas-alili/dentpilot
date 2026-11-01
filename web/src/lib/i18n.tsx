// Three languages, Azerbaijani by default (W2). The choice is stored on this
// device. AZ and RU texts are DRAFTS for receptionist review, like the bot texts.

import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";

export type Lang = "az" | "ru" | "en";
export const LANGS: { code: Lang; label: string }[] = [
  { code: "az", label: "Azərbaycanca" },
  { code: "ru", label: "Русский" },
  { code: "en", label: "English" },
];

const az = {
  loading: "Yüklənir…",
  error_generic: "Xəta baş verdi. Yenidən cəhd edin.",
  retry: "Yenidən cəhd et",
  cancel: "Ləğv et",
  back: "Geri",
  sign_out: "Çıxış",
  minutes: "{n} dəq",

  nav_inbox: "Gələnlər",
  nav_bookings: "Randevular",
  nav_conversations: "Söhbətlər",
  nav_today: "Bu gün",
  nav_settings: "Ayarlar",

  login_title: "Daxil olun",
  login_email: "E-poçt",
  login_password: "Şifrə",
  login_submit: "Daxil ol",
  login_forgot: "Şifrəni unutmusunuz?",
  login_reset_sent: "Şifrəni yeniləmək üçün e-poçtunuza link göndərdik.",
  login_invalid: "E-poçt və ya şifrə yanlışdır.",
  login_new_password: "Yeni şifrə",
  login_set_password: "Şifrəni yadda saxla",
  login_password_set: "Şifrə yeniləndi.",
  login_no_access: "Bu hesabın klinikaya girişi yoxdur. Administratora müraciət edin.",

  inbox_title: "Təsdiq gözləyən cavablar",
  inbox_empty: "Təsdiq gözləyən cavab yoxdur.",
  inbox_replying_to: "Pasiyentin mesajı",
  inbox_send: "Göndər",
  inbox_discard: "Göndərmə",
  inbox_template: "Şablon: {name}",
  inbox_interactive_note: "Düymələr və forma dəyişmir, yalnız mətn redaktə olunur.",
  inbox_sent: "Göndərildi.",
  inbox_discarded: "Göndərilmədi.",

  bookings_title: "Təsdiq gözləyən randevular",
  bookings_empty: "Təsdiq gözləyən randevu yoxdur.",
  bookings_duration: "Müddət",
  bookings_held: "Ayrılıb: {n} dəq",
  bookings_max: "Növbəti randevuya qədər ən çox {n} dəq",
  bookings_approve: "Təsdiqlə",
  bookings_reject: "İmtina et",
  bookings_reject_reason: "İmtina səbəbi (istəyə bağlı)",
  bookings_approved: "Randevu təsdiqləndi.",
  bookings_rejected: "Randevudan imtina edildi.",

  conv_title: "Söhbətlər",
  conv_filter_attention: "Diqqət tələb edir",
  conv_filter_open: "Açıq",
  conv_filter_all: "Hamısı",
  conv_empty: "Söhbət yoxdur.",
  conv_status_assistant: "Bot cavab verir",
  conv_status_handed_to_staff: "Administratorda",
  conv_status_escalated: "Təcili",
  conv_status_closed: "Bağlı",
  conv_drafts: "{n} qaralama",
  conv_reply_placeholder: "Cavab yazın…",
  conv_send: "Göndər",
  conv_return_to_bot: "Bota qaytar",
  conv_close: "Söhbəti bağla",
  conv_window_closed: "Pasiyent 24 saatdan çoxdur yazmayıb — WhatsApp sərbəst mətnə icazə vermir.",
  conv_from_bot: "Bot",
  conv_from_staff: "Klinika",
  conv_from_doctor: "Həkim (WhatsApp)",
  conv_draft: "Qaralama",
  conv_discarded: "Göndərilmədi",
  conv_failed: "Çatdırılmadı",

  today_title: "Günün randevuları",
  today_all: "Bütün həkimlər",
  today_mine: "Mənim",
  today_empty: "Bu gün üçün randevu yoxdur.",
  today_arrived: "Gəldi",
  today_done: "Bitdi",
  today_no_show: "Gəlmədi",
  today_cancel: "Ləğv et",
  today_confirm_cancel: "Bu randevu ləğv edilsin?",
  today_review: "Təsdiqə bax",
  st_pending_approval: "Təsdiq gözləyir",
  st_booked: "Yazılıb",
  st_confirmed: "Gələcəyini təsdiqləyib",
  st_checked_in: "Klinikadadır",
  st_completed: "Bitib",
  st_no_show: "Gəlməyib",

  settings_title: "Ayarlar",
  settings_language: "Dil",
  settings_push: "Bildirişlər",
  settings_push_enable: "Bildirişləri aç",
  settings_push_on: "Bu cihazda bildirişlər açıqdır.",
  settings_push_unsupported: "Bu brauzer bildirişləri dəstəkləmir.",
  settings_push_denied: "Bildirişlər brauzerdə bloklanıb. Brauzer ayarlarından icazə verin.",
  settings_calendar: "Google Təqvim",
  settings_calendar_connect: "Qoş",
  settings_calendar_reconnect: "Yenidən qoş",
  settings_calendar_connected: "Qoşulub: {email}",
  settings_calendar_none: "Qoşulmayıb",
  settings_calendar_broken: "Bağlantı kəsilib — yenidən qoşun.",
  cal_connected: "Google Təqvim qoşuldu.",
  cal_cancelled: "Qoşma ləğv edildi.",
  cal_invalid: "Link etibarsızdır və ya vaxtı keçib. Yenidən cəhd edin.",
  cal_failed: "Qoşmaq alınmadı. Yenidən cəhd edin.",
  settings_clinic: "Klinika ayarları",
  settings_shadow: "Kölgə rejimi",
  settings_shadow_hint: "Botun hər cavabı göndərilməzdən əvvəl təsdiq gözləyir.",
  settings_all_approval: "Bütün randevular həkim təsdiqi ilə",
  settings_saved: "Yadda saxlanıldı.",

  err_window_closed: "Pasiyent 24 saatdan çoxdur yazmayıb — WhatsApp sərbəst mətnə icazə vermir.",
  err_overlap: "Bu müddət növbəti randevu ilə üst-üstə düşür.",
  err_stale: "Bu artıq dəyişdirilib. Məlumat yeniləndi.",
  err_network: "Bağlantı xətası. İnterneti yoxlayın.",
};

export type TextKey = keyof typeof az;

const ru: Record<TextKey, string> = {
  loading: "Загрузка…",
  error_generic: "Произошла ошибка. Попробуйте ещё раз.",
  retry: "Повторить",
  cancel: "Отмена",
  back: "Назад",
  sign_out: "Выйти",
  minutes: "{n} мин",

  nav_inbox: "Входящие",
  nav_bookings: "Записи",
  nav_conversations: "Переписка",
  nav_today: "Сегодня",
  nav_settings: "Настройки",

  login_title: "Вход",
  login_email: "Эл. почта",
  login_password: "Пароль",
  login_submit: "Войти",
  login_forgot: "Забыли пароль?",
  login_reset_sent: "Мы отправили ссылку для сброса пароля на вашу почту.",
  login_invalid: "Неверная почта или пароль.",
  login_new_password: "Новый пароль",
  login_set_password: "Сохранить пароль",
  login_password_set: "Пароль обновлён.",
  login_no_access: "У этой учётной записи нет доступа к клинике. Обратитесь к администратору.",

  inbox_title: "Ответы на подтверждение",
  inbox_empty: "Нет ответов на подтверждение.",
  inbox_replying_to: "Сообщение пациента",
  inbox_send: "Отправить",
  inbox_discard: "Не отправлять",
  inbox_template: "Шаблон: {name}",
  inbox_interactive_note: "Кнопки и форма не меняются, можно изменить только текст.",
  inbox_sent: "Отправлено.",
  inbox_discarded: "Не отправлено.",

  bookings_title: "Записи на подтверждение",
  bookings_empty: "Нет записей на подтверждение.",
  bookings_duration: "Длительность",
  bookings_held: "Забронировано: {n} мин",
  bookings_max: "До следующей записи не больше {n} мин",
  bookings_approve: "Подтвердить",
  bookings_reject: "Отклонить",
  bookings_reject_reason: "Причина отказа (необязательно)",
  bookings_approved: "Запись подтверждена.",
  bookings_rejected: "Запись отклонена.",

  conv_title: "Переписка",
  conv_filter_attention: "Требуют внимания",
  conv_filter_open: "Открытые",
  conv_filter_all: "Все",
  conv_empty: "Нет переписок.",
  conv_status_assistant: "Отвечает бот",
  conv_status_handed_to_staff: "У администратора",
  conv_status_escalated: "Срочно",
  conv_status_closed: "Закрыта",
  conv_drafts: "Черновиков: {n}",
  conv_reply_placeholder: "Напишите ответ…",
  conv_send: "Отправить",
  conv_return_to_bot: "Вернуть боту",
  conv_close: "Закрыть переписку",
  conv_window_closed: "Пациент не писал больше 24 часов — WhatsApp не разрешает свободный текст.",
  conv_from_bot: "Бот",
  conv_from_staff: "Клиника",
  conv_from_doctor: "Врач (WhatsApp)",
  conv_draft: "Черновик",
  conv_discarded: "Не отправлено",
  conv_failed: "Не доставлено",

  today_title: "Записи на день",
  today_all: "Все врачи",
  today_mine: "Мои",
  today_empty: "На этот день записей нет.",
  today_arrived: "Пришёл",
  today_done: "Завершено",
  today_no_show: "Не пришёл",
  today_cancel: "Отменить",
  today_confirm_cancel: "Отменить эту запись?",
  today_review: "К подтверждению",
  st_pending_approval: "Ждёт подтверждения",
  st_booked: "Записан",
  st_confirmed: "Подтвердил визит",
  st_checked_in: "В клинике",
  st_completed: "Приём завершён",
  st_no_show: "Неявка",

  settings_title: "Настройки",
  settings_language: "Язык",
  settings_push: "Уведомления",
  settings_push_enable: "Включить уведомления",
  settings_push_on: "На этом устройстве уведомления включены.",
  settings_push_unsupported: "Этот браузер не поддерживает уведомления.",
  settings_push_denied: "Уведомления заблокированы в браузере. Разрешите их в настройках браузера.",
  settings_calendar: "Google Календарь",
  settings_calendar_connect: "Подключить",
  settings_calendar_reconnect: "Подключить заново",
  settings_calendar_connected: "Подключено: {email}",
  settings_calendar_none: "Не подключено",
  settings_calendar_broken: "Связь потеряна — подключите заново.",
  cal_connected: "Google Календарь подключён.",
  cal_cancelled: "Подключение отменено.",
  cal_invalid: "Ссылка недействительна или устарела. Попробуйте ещё раз.",
  cal_failed: "Не удалось подключить. Попробуйте ещё раз.",
  settings_clinic: "Настройки клиники",
  settings_shadow: "Теневой режим",
  settings_shadow_hint: "Каждый ответ бота ждёт подтверждения перед отправкой.",
  settings_all_approval: "Все записи — с подтверждением врача",
  settings_saved: "Сохранено.",

  err_window_closed: "Пациент не писал больше 24 часов — WhatsApp не разрешает свободный текст.",
  err_overlap: "Эта длительность пересекается со следующей записью.",
  err_stale: "Это уже изменили. Данные обновлены.",
  err_network: "Ошибка соединения. Проверьте интернет.",
};

const en: Record<TextKey, string> = {
  loading: "Loading…",
  error_generic: "Something went wrong. Please try again.",
  retry: "Try again",
  cancel: "Cancel",
  back: "Back",
  sign_out: "Sign out",
  minutes: "{n} min",

  nav_inbox: "Inbox",
  nav_bookings: "Bookings",
  nav_conversations: "Chats",
  nav_today: "Today",
  nav_settings: "Settings",

  login_title: "Sign in",
  login_email: "Email",
  login_password: "Password",
  login_submit: "Sign in",
  login_forgot: "Forgot your password?",
  login_reset_sent: "We sent a password reset link to your email.",
  login_invalid: "Wrong email or password.",
  login_new_password: "New password",
  login_set_password: "Save password",
  login_password_set: "Password updated.",
  login_no_access: "This account has no access to a clinic. Ask your administrator.",

  inbox_title: "Replies waiting for approval",
  inbox_empty: "No replies waiting for approval.",
  inbox_replying_to: "Patient's message",
  inbox_send: "Send",
  inbox_discard: "Don't send",
  inbox_template: "Template: {name}",
  inbox_interactive_note: "Buttons and forms stay as they are; only the text can be edited.",
  inbox_sent: "Sent.",
  inbox_discarded: "Not sent.",

  bookings_title: "Bookings waiting for approval",
  bookings_empty: "No bookings waiting for approval.",
  bookings_duration: "Duration",
  bookings_held: "Held: {n} min",
  bookings_max: "At most {n} min before the next booking",
  bookings_approve: "Approve",
  bookings_reject: "Reject",
  bookings_reject_reason: "Reason for rejecting (optional)",
  bookings_approved: "Booking approved.",
  bookings_rejected: "Booking rejected.",

  conv_title: "Chats",
  conv_filter_attention: "Needs attention",
  conv_filter_open: "Open",
  conv_filter_all: "All",
  conv_empty: "No chats.",
  conv_status_assistant: "Bot is answering",
  conv_status_handed_to_staff: "With staff",
  conv_status_escalated: "Urgent",
  conv_status_closed: "Closed",
  conv_drafts: "{n} draft(s)",
  conv_reply_placeholder: "Write a reply…",
  conv_send: "Send",
  conv_return_to_bot: "Hand back to bot",
  conv_close: "Close chat",
  conv_window_closed: "The patient hasn't written for over 24 hours — WhatsApp doesn't allow free text.",
  conv_from_bot: "Bot",
  conv_from_staff: "Clinic",
  conv_from_doctor: "Doctor (WhatsApp)",
  conv_draft: "Draft",
  conv_discarded: "Not sent",
  conv_failed: "Not delivered",

  today_title: "Day's bookings",
  today_all: "All dentists",
  today_mine: "Mine",
  today_empty: "No bookings on this day.",
  today_arrived: "Arrived",
  today_done: "Done",
  today_no_show: "No-show",
  today_cancel: "Cancel",
  today_confirm_cancel: "Cancel this booking?",
  today_review: "Review",
  st_pending_approval: "Waiting for approval",
  st_booked: "Booked",
  st_confirmed: "Confirmed attendance",
  st_checked_in: "In the clinic",
  st_completed: "Completed",
  st_no_show: "Didn't come",

  settings_title: "Settings",
  settings_language: "Language",
  settings_push: "Notifications",
  settings_push_enable: "Turn on notifications",
  settings_push_on: "Notifications are on for this device.",
  settings_push_unsupported: "This browser doesn't support notifications.",
  settings_push_denied: "Notifications are blocked in the browser. Allow them in the browser settings.",
  settings_calendar: "Google Calendar",
  settings_calendar_connect: "Connect",
  settings_calendar_reconnect: "Reconnect",
  settings_calendar_connected: "Connected: {email}",
  settings_calendar_none: "Not connected",
  settings_calendar_broken: "Connection lost — reconnect.",
  cal_connected: "Google Calendar connected.",
  cal_cancelled: "Connecting was cancelled.",
  cal_invalid: "The link is invalid or expired. Please try again.",
  cal_failed: "Couldn't connect. Please try again.",
  settings_clinic: "Clinic settings",
  settings_shadow: "Shadow mode",
  settings_shadow_hint: "Every bot reply waits for approval before it is sent.",
  settings_all_approval: "Every booking needs a doctor's approval",
  settings_saved: "Saved.",

  err_window_closed: "The patient hasn't written for over 24 hours — WhatsApp doesn't allow free text.",
  err_overlap: "That duration overlaps the next booking.",
  err_stale: "Someone changed this meanwhile. The data was refreshed.",
  err_network: "Connection problem. Check the internet.",
};

export const DICTIONARIES: Record<Lang, Record<TextKey, string>> = { az, ru, en };

export function translate(lang: Lang, key: TextKey, values: Record<string, string | number> = {}): string {
  return DICTIONARIES[lang][key].replace(/\{(\w+)\}/g, (m, k) => (k in values ? String(values[k]) : m));
}

const STORAGE_KEY = "dentpilot.lang";

function initialLang(): Lang {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "az" || saved === "ru" || saved === "en") return saved;
  } catch { /* storage unavailable */ }
  return "az";
}

interface I18n {
  lang: Lang;
  setLang: (lang: Lang) => void;
  t: (key: TextKey, values?: Record<string, string | number>) => string;
}

const I18nContext = createContext<I18n | null>(null);

export function I18nProvider({ children, lang: fixed }: { children: ReactNode; lang?: Lang }) {
  const [lang, setLangState] = useState<Lang>(fixed ?? initialLang());
  const setLang = useCallback((next: Lang) => {
    setLangState(next);
    try { localStorage.setItem(STORAGE_KEY, next); } catch { /* ignore */ }
    document.documentElement.lang = next;
  }, []);
  const value = useMemo<I18n>(() => ({ lang, setLang, t: (key, values) => translate(lang, key, values) }), [lang, setLang]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n outside I18nProvider");
  return ctx;
}
