// Dates and times as staff read them. Values from the API are already in
// clinic local time ("YYYY-MM-DDTHH:MI"), so no time-zone maths happens here.
import type { Lang } from "./i18n";

const MONTHS: Record<Lang, string[]> = {
  az: ["yanvar", "fevral", "mart", "aprel", "may", "iyun", "iyul", "avqust", "sentyabr", "oktyabr", "noyabr", "dekabr"],
  ru: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
  en: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
};

const WEEKDAYS: Record<Lang, string[]> = {   // ISO: index 1 = Monday … 7 = Sunday
  az: ["", "bazar ertəsi", "çərşənbə axşamı", "çərşənbə", "cümə axşamı", "cümə", "şənbə", "bazar"],
  ru: ["", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"],
  en: ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
};

/** "2026-11-02" or "2026-11-02T10:00" → "2 noyabr, bazar ertəsi" / "Monday, 2 November" */
export function formatDate(iso: string, lang: Lang): string {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  const weekday = WEEKDAYS[lang][new Date(Date.UTC(y, m - 1, d)).getUTCDay() || 7];
  return lang === "en" ? `${weekday}, ${d} ${MONTHS.en[m - 1]}` : `${d} ${MONTHS[lang][m - 1]}, ${weekday}`;
}

/** "2026-11-02T10:00" → "10:00" */
export function formatTime(localDateTime: string): string {
  return localDateTime.slice(11, 16);
}

/** Message timestamp (instant) shown in the viewer's own clock — staff are in the clinic. */
export function formatStamp(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** Today's date in a time zone, as YYYY-MM-DD. */
export function todayIn(timeZone: string, now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

/** "+994501234567"-style display of a WhatsApp id. */
export function formatPhone(waId: string): string {
  return waId ? `+${waId}` : "";
}

/** Duration choices for approval: 15-minute steps up to the cap, always including the held duration. */
export function durationOptions(held: number, max: number): number[] {
  const options = new Set<number>([held]);
  for (let m = 15; m <= max; m += 15) options.add(m);
  return [...options].filter((m) => m <= Math.max(max, held)).sort((a, b) => a - b);
}
